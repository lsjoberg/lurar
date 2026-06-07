import Foundation
import CoreAudio
import AudioToolbox
import AVFAudio
import Combine
import OSLog
import AppKit

private let log = Logger(subsystem: "app.lurar.Lurar", category: "EQEngine")

public enum EQProcessor {
    public enum Slot: Int, Codable { case a = 0, b = 1 }
}

nonisolated(unsafe) private var rtRingBuffer: AudioRingBuffer?
nonisolated(unsafe) private var rtChannelCount: UInt32 = 2
nonisolated(unsafe) private var rtScratchBuffer: UnsafeMutablePointer<Float>?
nonisolated(unsafe) private var rtScratchCapacity: Int = 0

nonisolated(unsafe) private var rtCrossfeed: Crossfeed?

private func renderCallback(
    _: UnsafeMutablePointer<ObjCBool>,
    _: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32,
    audioBufferList: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
    guard let ringBuf = rtRingBuffer else { return noErr }
    let ch = Int(rtChannelCount)
    let frames = Int(frameCount)
    let interleavedCount = frames * ch
    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)

    // The scratch buffer is pre-allocated in `start()` for the expected
    // maximum frame count, so this branch is a safety net only — allocating on
    // the render thread is a real-time hazard and should not happen in steady
    // state.
    if rtScratchCapacity < interleavedCount {
        rtScratchBuffer?.deallocate()
        rtScratchBuffer = .allocate(capacity: interleavedCount)
        rtScratchCapacity = interleavedCount
    }
    guard let scratch = rtScratchBuffer else { return noErr }

    let read = ringBuf.read(scratch, count: interleavedCount)
    if read < interleavedCount {
        scratch.advanced(by: read).initialize(repeating: 0.0, count: interleavedCount - read)
    }

    if bufferList.count >= 2,
       let outL = bufferList[0].mData?.assumingMemoryBound(to: Float.self),
       let outR = bufferList[1].mData?.assumingMemoryBound(to: Float.self) {
        
        for f in 0..<frames {
            outL[f] = scratch[f * ch + 0]
            outR[f] = scratch[f * ch + 1]
        }

        // Crossfeed runs unconditionally; an intensity of 0 is a pass-through,
        // which is how the UI's on/off toggle disables it.
        rtCrossfeed?.process(left: outL, right: outR, frames: frames)
    } else {
        // Fallback for single channel or other unexpected layouts
        for i in 0..<bufferList.count {
            guard let outData = bufferList[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channelIndex = min(i, ch - 1)
            for f in 0..<frames {
                outData[f] = scratch[f * ch + channelIndex]
            }
        }
    }

    return noErr
}

@MainActor
final class EQEngine: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isPlayingAudio: Bool = false
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var currentPreset: EQPreset?
    @Published private(set) var isInComparisonMode: Bool = false
    @Published private(set) var isBypassed: Bool = false
    @Published private(set) var loudnessOffsetDB: Float = 0
    @Published private(set) var activeOutput: AudioDevice?

    weak var excludedAppsStore: ExcludedAppsStore?

    let spectrumAnalyzer = SpectrumAnalyzer()
    let clipMeter = ClipMeter()
    let crossfeed = Crossfeed()

    static let loudnessOffsetRange: ClosedRange<Float> = -40...0
    static let loudnessOffsetDefaultsKey = "lurar.loudnessOffsetDB"
    static let muteOnDeviceRateChangeKey = "muteOnDeviceRateChange"
    
    private var engine: AVAudioEngine?
    private var eqNode: AVAudioUnitEQ?
    private var loudnessEQNode: AVAudioUnitEQ?
    private var limiterNode: AVAudioUnitEffect?
    private var sourceNode: AVAudioSourceNode?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapUUID = UUID()
    
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?

    private var bypassHotkey: BypassHotkey?
    
    private var comparisonPresetA: EQPreset?
    private var comparisonPresetB: EQPreset?
    private var matchGainA: Float = 0
    private var matchGainB: Float = 0
    private var activeComparisonSlot: EQProcessor.Slot = .a
    private var comparisonMuted: Bool = false

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.loudnessOffsetDefaultsKey) as? Double
        self.loudnessOffsetDB = Self.clampLoudness(Float(stored ?? 0))
        rtCrossfeed = crossfeed
        installDeviceChangeListener()
        wireUpBypassHotkey()
    }
    
    deinit {
        if let block = deviceChangeListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address,
                DispatchQueue.main, block
            )
        }
    }
    
    private func caCheck(_ status: OSStatus, _ message: String) throws {
        if status != noErr {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(message) (OSStatus \(status))"])
        }
    }

    func start(output: AudioDevice) {
        if isRunning && activeOutput?.id == output.id { return }
        stop()

        do {
            // 1. Get process PID to exclude ourselves
            var translateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var myPID = ProcessInfo.processInfo.processIdentifier
            var myProcessObjectID = AudioObjectID(kAudioObjectUnknown)
            var processObjectSize = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &translateAddress,
                UInt32(MemoryLayout<pid_t>.size), &myPID,
                &processObjectSize, &myProcessObjectID
            )

            // 2. Create muted global tap
            tapUUID = UUID()
            var excludeProcesses: [AudioObjectID] = myProcessObjectID != kAudioObjectUnknown ? [myProcessObjectID] : []
            if let store = excludedAppsStore {
                let pids = store.excludedBundleIDs.compactMap { bundleID -> pid_t? in
                    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
                }
                for pid in pids {
                    var pidVar = pid
                    var procObj = AudioObjectID(kAudioObjectUnknown)
                    var size = UInt32(MemoryLayout<AudioObjectID>.size)
                    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translateAddress, UInt32(MemoryLayout<pid_t>.size), &pidVar, &size, &procObj)
                    if status == noErr && procObj != kAudioObjectUnknown {
                        excludeProcesses.append(procObj)
                    }
                }
            }
            let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeProcesses)
            tapDesc.uuid = tapUUID
            tapDesc.muteBehavior = .muted
            tapDesc.name = "Lurar-Tap"

            tapID = AudioObjectID(kAudioObjectUnknown)
            try caCheck(AudioHardwareCreateProcessTap(tapDesc, &tapID), "Failed to create process tap")

            // 3. Read tap format
            var formatAddress = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var tapFormat = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try caCheck(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &tapFormat), "Failed to get tap format")
            let tapSampleRate = tapFormat.mSampleRate
            let channels = tapFormat.mChannelsPerFrame

            // Read output device native sample rate
            var nominalRateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceSampleRate: Float64 = 0
            var rateSize = UInt32(MemoryLayout<Float64>.size)
            AudioObjectGetPropertyData(output.id, &nominalRateAddress, 0, nil, &rateSize, &deviceSampleRate)

            let sampleRate = deviceSampleRate > 0 ? deviceSampleRate : tapSampleRate

            crossfeed.configure(sampleRate: sampleRate)
            spectrumAnalyzer.configure(sampleRate: sampleRate)
            clipMeter.configure(sampleRate: sampleRate)

            let outputUIDString = output.uid

            // 4. Create aggregate device
            let aggregateUID = UUID().uuidString
            let aggregateDesc: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Lurar-Aggregate",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUIDString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUIDString]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: tapUUID.uuidString,
                    ]
                ],
            ]

            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            try caCheck(AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggregateDeviceID), "Failed to create aggregate device")

            // Wait for device alive
            var aliveAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            for _ in 1...30 {
                var isAlive: UInt32 = 0
                var aliveSize = UInt32(MemoryLayout<UInt32>.size)
                AudioObjectGetPropertyData(aggregateDeviceID, &aliveAddress, 0, nil, &aliveSize, &isAlive)
                if isAlive != 0 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }

            // 5. Setup AVAudioEngine
            let bufferSeconds = 0.5
            let ringBuf = AudioRingBuffer(capacityFrames: Int(sampleRate * bufferSeconds), channels: Int(channels))
            rtRingBuffer = ringBuf
            rtChannelCount = channels

            // Pre-allocate the render scratch buffer so the real-time render
            // callback never has to allocate. 4096 frames comfortably exceeds
            // the source node's render quantum; the callback keeps a grow guard
            // purely as a safety net.
            let maxRenderFrames = 4096
            let scratchCapacity = maxRenderFrames * Int(channels)
            rtScratchBuffer?.deallocate()
            rtScratchBuffer = .allocate(capacity: scratchCapacity)
            rtScratchCapacity = scratchCapacity

            let avEngine = AVAudioEngine()

            var outputID = output.id
            let outputAU = avEngine.outputNode.audioUnit!
            AudioUnitSetProperty(
                outputAU,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &outputID, UInt32(MemoryLayout<AudioDeviceID>.size)
            )

            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
            let srcNode = AVAudioSourceNode(format: format, renderBlock: renderCallback)
            self.sourceNode = srcNode

            let mainEQ = AVAudioUnitEQ(numberOfBands: 10)
            self.eqNode = mainEQ

            // Loudness compensation is a frequency-dependent (ISO 226) contour,
            // not a flat gain — give the node enough bands to hold the fitted
            // cascade. Populated in `applyAudioState()`.
            let loudEQ = AVAudioUnitEQ(numberOfBands: LoudnessContour.sectionCount)
            self.loudnessEQNode = loudEQ

            let limiterDesc = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            let limiter = AVAudioUnitEffect(audioComponentDescription: limiterDesc)
            let au = limiter.audioUnit
            AudioUnitSetParameter(au, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.007, 0)
            AudioUnitSetParameter(au, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.024, 0)
            AudioUnitSetParameter(au, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0.0, 0)
            self.limiterNode = limiter

            avEngine.attach(srcNode)
            avEngine.attach(mainEQ)
            avEngine.attach(loudEQ)
            avEngine.attach(limiter)
            avEngine.connect(srcNode, to: mainEQ, format: format)
            avEngine.connect(mainEQ, to: loudEQ, format: format)
            avEngine.connect(loudEQ, to: limiter, format: format)
            avEngine.connect(limiter, to: avEngine.outputNode, format: format)

            try avEngine.start()
            self.engine = avEngine
            
            // Install taps for SpectrumAnalyzer and ClipMeter
            let analyzer = self.spectrumAnalyzer
            let meter = self.clipMeter
            let capturedSampleRate = sampleRate
            
            mainEQ.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
                guard let channelData = buffer.floatChannelData else { return }
                let frameLength = Int(buffer.frameLength)
                if frameLength > 0 && buffer.format.channelCount >= 2 {
                    analyzer.submit(left: channelData[0], right: channelData[1], frames: frameLength)
                }
            }
            limiter.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
                guard let channelData = buffer.floatChannelData else { return }
                let frameLength = Int(buffer.frameLength)
                if frameLength > 0 && buffer.format.channelCount >= 2 {
                    meter.submit(left: channelData[0], right: channelData[1], frames: frameLength)
                }
            }

            // 6. Install IOProc on aggregate device
            let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
                guard let ringBuf = rtRingBuffer else { return }

                let inBufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                for i in 0..<inBufList.count {
                    guard let data = inBufList[i].mData else { continue }
                    let sampleCount = Int(inBufList[i].mDataByteSize) / MemoryLayout<Float>.size
                    ringBuf.write(data.assumingMemoryBound(to: Float.self), count: sampleCount)
                }

                let outBufList = UnsafeMutableAudioBufferListPointer(outOutputData)
                for i in 0..<outBufList.count {
                    if let data = outBufList[i].mData {
                        memset(data, 0, Int(outBufList[i].mDataByteSize))
                    }
                }
            }
            try caCheck(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil, ioBlock), "Failed to create IOProc")
            try caCheck(AudioDeviceStart(aggregateDeviceID, procID), "Failed to start IOProc")

            activeOutput = output
            isRunning = true
            isPlayingAudio = true // Playback polling is removed; we consider it playing if running.
            statusMessage = "Running"
            
            applyAudioState()

        } catch {
            reportStartFailure(error.localizedDescription)
            stop()
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        guard isRunning else {
            completion?()
            return
        }
        isRunning = false
        isPlayingAudio = false
        statusMessage = "Stopped"

        rtRingBuffer = nil
        
        eqNode?.removeTap(onBus: 0)
        limiterNode?.removeTap(onBus: 0)

        if let procID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            self.procID = nil
        }
        
        engine?.stop()
        engine = nil
        eqNode = nil
        loudnessEQNode = nil
        limiterNode = nil
        sourceNode = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        
        activeOutput = nil
        
        if isInComparisonMode {
            isInComparisonMode = false
        }
        if isBypassed {
            isBypassed = false
        }
        
        completion?()
    }
    
    private func applyAudioState() {
        guard let eq = eqNode, let loudEQ = loudnessEQNode else { return }
        
        if comparisonMuted {
            eq.globalGain = -100
            return
        }
        
        applyLoudnessContour(to: loudEQ)

        if isBypassed {
            eq.bypass = true
        } else {
            eq.bypass = false
            
            let presetToApply: EQPreset?
            let preampOffset: Float
            
            if isInComparisonMode {
                if activeComparisonSlot == .a {
                    presetToApply = comparisonPresetA
                    preampOffset = matchGainA
                } else {
                    presetToApply = comparisonPresetB
                    preampOffset = matchGainB
                }
            } else {
                presetToApply = currentPreset
                preampOffset = 0
            }
            
            if let preset = presetToApply {
                eq.globalGain = preset.preamp + preampOffset
                
                let bandsCount = preset.bands.count
                for (i, avBand) in eq.bands.enumerated() {
                    if i < bandsCount {
                        let b = preset.bands[i]
                        avBand.filterType = b.type.avType
                        avBand.frequency = b.frequency
                        avBand.gain = b.gain
                        avBand.bandwidth = EQBand.qToOctaves(b.q)
                        avBand.bypass = false
                    } else {
                        avBand.bypass = true
                    }
                }
            } else {
                eq.globalGain = 0
                for avBand in eq.bands {
                    avBand.bypass = true
                }
            }
        }
    }

    /// Fit the ISO 226 equal-loudness compensation curve for the current offset
    /// onto the loudness EQ node. This is a frequency-dependent contour (bass/
    /// treble shelving relative to the mids), not a flat attenuation — the node
    /// carries `LoudnessContour.sectionCount` bands and a negative global gain
    /// equal to the fitted curve's peak so the boost can't push into clipping.
    private func applyLoudnessContour(to loudEQ: AVAudioUnitEQ) {
        let (bands, headroomDB) = LoudnessContour.loudnessBands(offsetDB: Double(loudnessOffsetDB))
        for (i, avBand) in loudEQ.bands.enumerated() {
            if i < bands.count {
                let b = bands[i]
                avBand.filterType = b.type.avType
                avBand.frequency = b.frequency
                avBand.gain = b.gain
                avBand.bandwidth = EQBand.qToOctaves(b.q)
                avBand.bypass = false
            } else {
                avBand.bypass = true
            }
        }
        loudEQ.globalGain = -Float(headroomDB)
    }

    func reportStartFailure(_ message: String) {
        isRunning = false
        statusMessage = message
        log.error("Start blocked: \(message)")
    }
    
    func reEnumerateTapTargets() {
        guard isRunning, let activeOutput = activeOutput else { return }
        start(output: activeOutput)
    }

    // MARK: - Preset / band updates

    func apply(preset: EQPreset) {
        if isInComparisonMode {
            isInComparisonMode = false
        }
        if isBypassed {
            isBypassed = false
        }
        currentPreset = preset
        applyAudioState()
    }

    func updateBand(index: Int, band: EQBand) {
        guard !isInComparisonMode, !isBypassed else { return }
        if var p = currentPreset, p.bands.indices.contains(index) {
            p.bands[index] = band
            currentPreset = p
        }
        applyAudioState()
    }

    func setPreamp(_ dB: Float) {
        guard !isInComparisonMode, !isBypassed else { return }
        if var p = currentPreset {
            p.preamp = dB
            currentPreset = p
        }
        applyAudioState()
    }

    // MARK: - Crossfeed

    func setCrossfeedIntensity(_ value: Float) {
        crossfeed.setIntensity(value)
    }

    func setCrossfeedCutoff(_ hz: Float) {
        crossfeed.setCutoff(hz)
    }

    // MARK: - Loudness compensation

    func setLoudnessOffset(_ dB: Float) {
        let clamped = Self.clampLoudness(dB)
        if clamped == loudnessOffsetDB { return }
        loudnessOffsetDB = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.loudnessOffsetDefaultsKey)
        applyAudioState()
    }

    private static func clampLoudness(_ dB: Float) -> Float {
        min(max(dB, loudnessOffsetRange.lowerBound), loudnessOffsetRange.upperBound)
    }

    // MARK: - A/B comparison

    func loadComparisonSlots(
        presetA: EQPreset,
        presetB: EQPreset,
        matchGainA: Float,
        matchGainB: Float
    ) {
        if isBypassed { isBypassed = false }
        comparisonPresetA = presetA
        comparisonPresetB = presetB
        self.matchGainA = matchGainA
        self.matchGainB = matchGainB
        isInComparisonMode = true
        applyAudioState()
    }

    func setComparisonSlot(_ slot: EQProcessor.Slot) {
        guard isInComparisonMode else { return }
        activeComparisonSlot = slot
        applyAudioState()
    }

    func setComparisonMute(_ muted: Bool) {
        guard isInComparisonMode else { return }
        comparisonMuted = muted
        applyAudioState()
    }

    func exitComparisonMode() {
        guard isInComparisonMode else { return }
        isInComparisonMode = false
        applyAudioState()
    }

    // MARK: - Bypass

    func wireUpBypassHotkey() {
        guard bypassHotkey == nil else { return }
        bypassHotkey = BypassHotkey(engine: self)
    }

    func setBypassed(_ on: Bool) {
        if on == isBypassed { return }
        if isInComparisonMode { return }
        isBypassed = on
        applyAudioState()
    }
    
    // MARK: - Device Change Handling

    private func installDeviceChangeListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleDeviceChange()
                }
            }
        }
        deviceChangeListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address,
            DispatchQueue.main, block
        )
    }

    private func handleDeviceChange() {
        // Just let LurarApp or DeviceManager handle restarting the engine with the new output, 
        // as they monitor device topology already.
    }
}
