import Foundation
import AudioToolbox
import CoreAudio
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "ProcessTapInput")

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

    private var tapID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
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
    /// target list and bypass Klang entirely (their audio flows through the
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
        //    Note: apps that start producing audio *after* this point won't be tapped
        //    until the engine is restarted.
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
        description.name = "Klang System Tap"
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
        let mainSubDeviceUID = try Self.systemDefaultOutputUID()
        let aggregateUID = "se.linus.klang.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Klang System Tap (private)",
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

        // Deinterleaved stereo: 2 separate buffers, one per channel.
        if abl.count >= 2,
           let leftRaw = abl[0].mData,
           let rightRaw = abl[1].mData {
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            handler(leftRaw.assumingMemoryBound(to: Float.self),
                    rightRaw.assumingMemoryBound(to: Float.self),
                    frames)
            return
        }

        // Interleaved fallback: 1 buffer, 2 channels. Deinterleave into scratch.
        if abl.count == 1,
           let raw = abl[0].mData,
           let l = leftScratch,
           let r = rightScratch {
            let channels = Int(abl[0].mNumberChannels)
            let totalFloats = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
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

    private static func systemDefaultOutputUID() throws -> String {
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
        return cf as String
    }
}
