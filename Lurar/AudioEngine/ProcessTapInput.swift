import Foundation
import AudioToolbox
import CoreAudio
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "ProcessTapInput")

/// Captures system audio output via a Core Audio Process Tap (macOS 14.2+) wrapped in a
/// private aggregate device. We read samples by attaching an `AudioDeviceIOProc`
/// directly to the aggregate — *not* via a HAL Output AU with input enabled. That
/// distinction matters: an aggregate read through a HAL AU input is still treated as
/// microphone capture and trips the orange privacy indicator, while a direct IOProc on
/// a tap-backed aggregate is not.
///
/// Lifetime:
///   prepare() → creates tap + aggregate → returns `(deviceID, sampleRate)`
///   start()   → installs IOProc on the aggregate and starts the device
///   stop()    → stops device, destroys IOProc, destroys aggregate, destroys tap
final class ProcessTapInput {
    typealias FrameHandler = (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) -> Void

    /// Aggregate device ID after `prepare()`. Zero before prepare / after stop.
    private(set) var deviceID: AudioDeviceID = 0

    /// The process objects the live tap was built around. A tap's target list
    /// is fixed at creation time, so `EQEngine` diffs this against the current
    /// system process list to notice apps that started producing audio after
    /// the tap was created and rebuild for them.
    private(set) var tappedProcessObjects: Set<AudioObjectID> = []

    private var tapID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?

    /// Index of the first buffer that belongs to the tap in the aggregate's input
    /// AudioBufferList. The list is laid out as
    ///   [main sub-device input streams…] + [tap streams…]
    /// so an output device that also has inputs (any audio interface) contributes
    /// its own line/mic streams first. Those must be skipped.
    private var tapBufferStartIndex: Int = 0
    private var frameHandler: FrameHandler?

    /// Per-channel scratch used to deinterleave the tap's interleaved buffer for the
    /// EQ processor (which expects two separate Float32 channel buffers).
    private var leftScratch: UnsafeMutablePointer<Float>?
    private var rightScratch: UnsafeMutablePointer<Float>?
    private var scratchCapacityFrames: Int = 0
    private let maxFrames: Int = 4096

    deinit { try? stop() }

    // MARK: - Lifecycle

    /// Creates the process tap and a private aggregate device that wraps it. Returns the
    /// aggregate device ID and its nominal sample rate (which follows the tap).
    ///
    /// `excludedBundleIDs` is the user's per-app exclusion list — process objects
    /// whose `kAudioProcessPropertyBundleID` matches are dropped from the tap
    /// target list and bypass Lurar entirely (their audio flows through the
    /// system mixer's normal output path).
    func prepare(excludedBundleIDs: Set<String> = []) throws -> (deviceID: AudioDeviceID, sampleRate: Double) {
        try teardownTapAndAggregate()

        // 1. Look up our own audio process object so we can exclude ourselves from the
        //    tap targets — otherwise HALOutput's playback to the DAC would loop back
        //    into the tap.
        let ownProcessObject = try AudioProcessInfo.processObject(for: getpid())

        // 2. Enumerate every audio process the system knows about and pass them
        //    explicitly to `stereoMixdownOfProcesses`. The seemingly-equivalent
        //    `stereoGlobalTapButExcludeProcesses` convenience init delivers silent
        //    buffers in the presence of 3rd-party audio drivers (Rogue Amoeba's ARK
        //    in particular) — the explicit-include form works around it.
        //    Note: apps that start producing audio *after* this point aren't part of
        //    this tap — a tap's target list can't be edited once created. The engine
        //    watches for that (see `EQEngine.refreshTapTargetsIfNeeded`) and rebuilds
        //    the tap, using `tappedProcessObjects` below as the reference set.
        let allProcesses = (try? AudioProcessInfo.allProcessObjects()) ?? []
        var excludedCount = 0
        let targets = allProcesses.filter { obj in
            if obj == ownProcessObject { return false }
            if !excludedBundleIDs.isEmpty,
               let bundleID = AudioProcessInfo.bundleID(for: obj),
               excludedBundleIDs.contains(bundleID) {
                excludedCount += 1
                return false
            }
            return true
        }
        guard !targets.isEmpty else {
            throw CoreAudioError.osStatus(-1, "no audio processes available to tap")
        }
        log.info("Tap targets: count=\(targets.count) excludedByUser=\(excludedCount)")

        let tapUUID = UUID()
        let description = CATapDescription(stereoMixdownOfProcesses: targets)
        description.uuid = tapUUID
        description.name = "Lurar System Tap"
        // .mutedWhenTapped silences source apps' direct output at their device while
        // we're consuming, so the user hears only the EQ'd version via HALOutput.
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.isExclusive = false
        description.isMixdown = true
        description.isMono = false

        var newTapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        if tapStatus != noErr {
            throw CoreAudioError.osStatus(tapStatus, "AudioHardwareCreateProcessTap")
        }
        self.tapID = newTapID

        // 3. Build the aggregate device. Mirrors Apple's CapturingSystemAudio sample:
        //    - MainSubDevice = system default output (provides the IO clock)
        //    - SubDeviceList containing the same output device
        //    - Tap entry references `tapDescription.uuid.uuidString` — *not* the tap
        //      object's `kAudioTapPropertyUID`. Passing the wrong one makes the
        //      aggregate accept the tap but deliver only zeros.
        let mainSubDevice = try Self.systemDefaultOutput()
        let mainSubDeviceUID = mainSubDevice.uid
        let aggregateUID = "app.lurar.Lurar.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Lurar System Tap (private)",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: mainSubDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: mainSubDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: tapUUID.uuidString
                ]
            ]
        ]

        var newAggregateID: AudioDeviceID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        if aggStatus != noErr {
            AudioHardwareDestroyProcessTap(newTapID)
            self.tapID = 0
            throw CoreAudioError.osStatus(aggStatus, "AudioHardwareCreateAggregateDevice")
        }
        self.deviceID = newAggregateID
        self.tappedProcessObjects = Set(targets)
        self.tapBufferStartIndex = Self.inputBufferCount(of: mainSubDevice.id)
        log.info("Aggregate input layout: skipping \(self.tapBufferStartIndex) sub-device input buffer(s)")

        let sampleRate = try CoreAudioSampleRate.nominal(for: newAggregateID)
        log.info("Process tap ready: tapID=\(newTapID) aggregateID=\(newAggregateID) rate=\(sampleRate)")
        return (newAggregateID, sampleRate)
    }

    /// Installs an IOProc on the aggregate device and starts it. The IOProc forwards
    /// tap-captured stereo audio to `frameHandler` on the audio thread.
    func start(frameHandler: @escaping FrameHandler) throws {
        guard deviceID != 0 else {
            throw CoreAudioError.osStatus(-1, "ProcessTapInput.start called before prepare")
        }
        try stopIOProc()

        self.frameHandler = frameHandler
        allocateScratch(maxFrames: maxFrames)

        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            deviceID,
            nil
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handle(inputData: inInputData)
        }
        if createStatus != noErr {
            throw CoreAudioError.osStatus(createStatus, "AudioDeviceCreateIOProcIDWithBlock")
        }
        guard let procID = newProcID else {
            throw CoreAudioError.osStatus(-1, "IOProc ID nil")
        }
        self.procID = procID

        let startStatus = AudioDeviceStart(deviceID, procID)
        if startStatus != noErr {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
            throw CoreAudioError.osStatus(startStatus, "AudioDeviceStart (aggregate)")
        }

        log.info("ProcessTapInput IOProc started on aggregate \(self.deviceID)")
    }

    func stop() throws {
        try stopIOProc()
        try teardownTapAndAggregate()
    }

    private func stopIOProc() throws {
        if let procID, deviceID != 0 {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        frameHandler = nil
        freeScratch()
    }

    private func teardownTapAndAggregate() throws {
        tappedProcessObjects = []
        tapBufferStartIndex = 0
        if deviceID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(deviceID)
            if status != noErr {
                log.warning("AudioHardwareDestroyAggregateDevice(\(self.deviceID)) returned \(status)")
            }
            deviceID = 0
        }
        if tapID != 0 {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                log.warning("AudioHardwareDestroyProcessTap(\(self.tapID)) returned \(status)")
            }
            tapID = 0
        }
    }

    // MARK: - Scratch buffer management

    private func allocateScratch(maxFrames: Int) {
        freeScratch()
        leftScratch = .allocate(capacity: maxFrames)
        rightScratch = .allocate(capacity: maxFrames)
        leftScratch!.initialize(repeating: 0, count: maxFrames)
        rightScratch!.initialize(repeating: 0, count: maxFrames)
        scratchCapacityFrames = maxFrames
    }

    private func freeScratch() {
        if let p = leftScratch { p.deallocate(); leftScratch = nil }
        if let p = rightScratch { p.deallocate(); rightScratch = nil }
        scratchCapacityFrames = 0
    }

    // MARK: - Audio thread

    private func handle(inputData: UnsafePointer<AudioBufferList>) {
        guard let handler = frameHandler else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard abl.count > 0 else { return }

        // Skip the main sub-device's own input streams. Without this an audio
        // interface's line inputs are read as the left channel and the tap — still
        // interleaved — as the right, which plays back one octave down at half speed.
        var start = tapBufferStartIndex
        if start >= abl.count { start = abl.count - 1 }
        let remaining = abl.count - start

        // Deinterleaved stereo tap: two single-channel buffers.
        if remaining >= 2,
           abl[start].mNumberChannels == 1,
           abl[start + 1].mNumberChannels == 1,
           let leftRaw = abl[start].mData,
           let rightRaw = abl[start + 1].mData {
            let frames = Int(abl[start].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            handler(leftRaw.assumingMemoryBound(to: Float.self),
                    rightRaw.assumingMemoryBound(to: Float.self),
                    frames)
            return
        }

        // Interleaved tap: one buffer carrying N channels. Deinterleave into scratch.
        if let raw = abl[start].mData,
           let l = leftScratch,
           let r = rightScratch {
            let channels = Int(abl[start].mNumberChannels)
            let totalFloats = Int(abl[start].mDataByteSize) / MemoryLayout<Float>.size
            let frames = channels > 0 ? totalFloats / channels : 0
            guard frames > 0, frames <= scratchCapacityFrames else { return }
            let interleaved = raw.assumingMemoryBound(to: Float.self)
            if channels >= 2 {
                for i in 0..<frames {
                    l[i] = interleaved[i * channels]
                    r[i] = interleaved[i * channels + 1]
                }
            } else {
                // Mono: duplicate to both channels.
                for i in 0..<frames {
                    let s = interleaved[i]
                    l[i] = s
                    r[i] = s
                }
            }
            handler(l, r, frames)
        }
    }

    // MARK: - Core Audio object helpers

    /// How many *input* buffers a device contributes when used as an aggregate
    /// sub-device. Zero for a plain output device (speakers, DAC, monitor).
    private static func inputBufferCount(of deviceID: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + ($1.mNumberChannels > 0 ? 1 : 0) }
    }

    private static func systemDefaultOutput() throws -> (id: AudioDeviceID, uid: String) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let s1 = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        if s1 != noErr {
            throw CoreAudioError.osStatus(s1, "default output device")
        }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfRef: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let s2 = AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &cfRef)
        if s2 != noErr {
            throw CoreAudioError.osStatus(s2, "default output UID")
        }
        guard let cf = cfRef?.takeRetainedValue() else {
            throw CoreAudioError.osStatus(-1, "default output UID nil")
        }
        return (deviceID, cf as String)
    }
}
