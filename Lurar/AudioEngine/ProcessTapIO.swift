import Foundation
import AudioToolbox
import CoreAudio
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "ProcessTapIO")

/// Captures system audio via a Core Audio Process Tap (macOS 14.2+) **and** plays the
/// processed result back to the chosen output device from a *single* IOProc — no
/// resampler, no ring buffer, no second real-time thread.
///
/// The aggregate device is built with the user's output device as its **main
/// sub-device** (the master clock + the physical output) and the process tap as an
/// input stream. Because both live in one aggregate on one IO clock, every IOProc
/// callback hands us the tap's captured buffers (`inInputData`) *and* the output
/// device's buffers (`outOutputData`) at the *same* sample rate. We run the EQ in
/// place on the captured audio and copy it straight into the output buffers — there's
/// nothing to convert and nothing to hand across threads.
///
/// This is the change that took idle/playback CPU from ~10%/33% down to low single
/// digits (issue #101): the old design read the tap on one device thread, resampled
/// every buffer, wrote a ring buffer, and replayed it on a *separate* HAL Output AU
/// thread. All of that is gone.
///
/// Reading the tap via an `AudioDeviceIOProc` on a private aggregate (rather than a HAL
/// input AU) is what keeps the orange microphone privacy indicator off.
///
/// Lifetime:
///   prepare() → creates tap + aggregate (output device as main sub) → `(deviceID, sampleRate)`
///   start()   → installs the in-place IOProc and starts the aggregate
///   stop()    → stops device, destroys IOProc, destroys aggregate, destroys tap
final class ProcessTapIO {
    /// In-place DSP stage. Receives writable deinterleaved L/R captured from the tap;
    /// mutates them (EQ, crossfeed, metering, output gain) before they're copied to
    /// the output device. `frames` is the count to process this callback.
    typealias FrameHandler = (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) -> Void

    /// Aggregate device ID after `prepare()`. Zero before prepare / after stop.
    private(set) var deviceID: AudioDeviceID = 0

    private var tapID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private var frameHandler: FrameHandler?

    /// Per-channel scratch used to deinterleave an interleaved tap buffer into the two
    /// separate Float32 channel buffers the DSP chain expects. Unused on the common
    /// non-interleaved path (we process the tap's own buffers in place there).
    private var leftScratch: UnsafeMutablePointer<Float>?
    private var rightScratch: UnsafeMutablePointer<Float>?
    private var scratchCapacityFrames: Int = 0
    /// Generous cap so transient large render bursts during a device-rate change
    /// (which can exceed the 512-frame steady-state buffer) still fit the scratch
    /// used by the interleaved-input path.
    private let maxFrames: Int = 8192

    deinit { try? stop() }

    // MARK: - Lifecycle

    /// Creates the process tap and a private aggregate device whose **main sub-device is
    /// `outputDeviceUID`** — the device Lurar plays the EQ'd audio back on. Returns the
    /// aggregate device ID and its nominal sample rate (which follows the output device).
    ///
    /// `excludedBundleIDs` is the user's per-app exclusion list — process objects whose
    /// `kAudioProcessPropertyBundleID` matches are dropped from the tap target list and
    /// bypass Lurar entirely (their audio flows through the system mixer's normal path).
    func prepare(
        outputDeviceUID: String,
        excludedBundleIDs: Set<String> = []
    ) throws -> (deviceID: AudioDeviceID, sampleRate: Double) {
        try teardownTapAndAggregate()

        // 1. Look up our own audio process object so we can exclude ourselves from the
        //    tap targets — otherwise our own playback to the output device would loop
        //    back into the tap.
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
        description.name = "Lurar System Tap"
        // .mutedWhenTapped silences source apps' direct output at their device while
        // we're consuming, so the user hears only the EQ'd version we play back.
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

        // 3. Build the aggregate device. Unlike a capture-only tap setup, the output
        //    device IS the main sub-device here: it provides the master IO clock and,
        //    crucially, the output streams our IOProc writes the EQ'd audio into. The
        //    tap rides the same clock (with drift compensation), so input and output
        //    arrive at the same rate in one callback — no SRC, no ring buffer.
        //
        //    Tap entry references `tapDescription.uuid.uuidString` — *not* the tap
        //    object's `kAudioTapPropertyUID`. Passing the wrong one makes the aggregate
        //    accept the tap but deliver only zeros.
        let aggregateUID = "app.lurar.Lurar.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Lurar System Tap (private)",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID]
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
        log.info("Process tap ready: tapID=\(newTapID) aggregateID=\(newAggregateID) outputUID=\(outputDeviceUID) rate=\(sampleRate)")
        return (newAggregateID, sampleRate)
    }

    /// Installs the in-place IOProc on the aggregate and starts it. On every callback the
    /// IOProc deinterleaves the tap's captured stereo, hands it to `frameHandler` for DSP,
    /// then copies the result into the output device's buffers — all on the audio thread.
    func start(frameHandler: @escaping FrameHandler) throws {
        guard deviceID != 0 else {
            throw CoreAudioError.osStatus(-1, "ProcessTapIO.start called before prepare")
        }
        try stopIOProc()

        self.frameHandler = frameHandler
        allocateScratch(maxFrames: maxFrames)

        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            deviceID,
            nil
        ) { [weak self] _, inInputData, _, outOutputData, _ in
            self?.render(input: inInputData, output: outOutputData)
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

        log.info("ProcessTapIO in-place IOProc started on aggregate \(self.deviceID)")
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

    /// One IOProc callback: deinterleave tap input → DSP in place → copy to output.
    private func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let outABL = UnsafeMutableAudioBufferListPointer(output)
        guard outABL.count > 0 else { return }
        let outputFrames = Self.frameCount(of: outABL)

        // Resolve writable L/R for the captured tap audio.
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var inLeft: UnsafeMutablePointer<Float>?
        var inRight: UnsafeMutablePointer<Float>?
        var inputFrames = 0

        if inABL.count >= 2,
           let leftRaw = inABL[0].mData,
           let rightRaw = inABL[1].mData {
            // Deinterleaved stereo: two channel buffers. Process them in place.
            inputFrames = Int(inABL[0].mDataByteSize) / MemoryLayout<Float>.size
            inLeft = leftRaw.assumingMemoryBound(to: Float.self)
            inRight = rightRaw.assumingMemoryBound(to: Float.self)
        } else if inABL.count == 1,
                  let raw = inABL[0].mData,
                  let ls = leftScratch,
                  let rs = rightScratch {
            // Interleaved fallback: deinterleave into scratch.
            let channels = Int(inABL[0].mNumberChannels)
            let totalFloats = Int(inABL[0].mDataByteSize) / MemoryLayout<Float>.size
            let frames = channels > 0 ? totalFloats / channels : 0
            let n = min(frames, scratchCapacityFrames)
            let interleaved = raw.assumingMemoryBound(to: Float.self)
            if channels >= 2 {
                for i in 0..<n {
                    ls[i] = interleaved[i * channels]
                    rs[i] = interleaved[i * channels + 1]
                }
            } else {
                for i in 0..<n {
                    let s = interleaved[i]
                    ls[i] = s
                    rs[i] = s
                }
            }
            inputFrames = n
            inLeft = ls
            inRight = rs
        }

        guard let left = inLeft, let right = inRight, inputFrames > 0, outputFrames > 0 else {
            // No usable input this callback — emit silence so the DAC never gets stale
            // or uninitialized memory.
            Self.zeroOutput(outABL)
            return
        }

        // On one aggregate clock input and output frame counts match; `min` is just
        // defensive against a transient mismatch during a rate change.
        let frames = min(inputFrames, outputFrames)

        // In-place DSP: crossfeed → EQ → metering → output gain. The closure mutates
        // the L/R buffers; we then copy the EQ'd result into the device's output.
        frameHandler?(left, right, frames)

        Self.writeOutput(outABL, left: left, right: right, frames: frames)
    }

    /// Frame count an output `AudioBufferList` can hold, inferred from its layout.
    private static func frameCount(of abl: UnsafeMutableAudioBufferListPointer) -> Int {
        guard abl.count > 0 else { return 0 }
        let first = abl[0]
        if abl.count >= 2 {
            // Non-interleaved: each buffer is one channel of Float32.
            return Int(first.mDataByteSize) / MemoryLayout<Float>.size
        }
        let channels = max(1, Int(first.mNumberChannels))
        return Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
    }

    /// Copy stereo L/R into the output buffer list, honouring its channel layout.
    /// Channels beyond the first two are filled with silence; any frames the input
    /// fell short of are zero-padded.
    private static func writeOutput(
        _ abl: UnsafeMutableAudioBufferListPointer,
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frames: Int
    ) {
        if abl.count >= 2 {
            // Non-interleaved: channel 0 = L, channel 1 = R, extra channels silent.
            for (idx, buffer) in abl.enumerated() {
                guard let raw = buffer.mData else { continue }
                let dst = raw.assumingMemoryBound(to: Float.self)
                let cap = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let n = min(frames, cap)
                switch idx {
                case 0:
                    dst.update(from: left, count: n)
                    if n < cap { dst.advanced(by: n).update(repeating: 0, count: cap - n) }
                case 1:
                    dst.update(from: right, count: n)
                    if n < cap { dst.advanced(by: n).update(repeating: 0, count: cap - n) }
                default:
                    dst.update(repeating: 0, count: cap)
                }
            }
            return
        }

        // Single buffer.
        guard let raw = abl[0].mData else { return }
        let channels = max(1, Int(abl[0].mNumberChannels))
        let dst = raw.assumingMemoryBound(to: Float.self)
        let cap = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
        if channels == 1 {
            let n = min(frames, cap)
            for i in 0..<n { dst[i] = 0.5 * (left[i] + right[i]) }
            if n < cap { dst.advanced(by: n).update(repeating: 0, count: cap - n) }
            return
        }
        // Interleaved, ≥2 channels: zero everything first (covers extra channels and
        // the short-frame tail), then lay L/R into the first two channels.
        dst.update(repeating: 0, count: cap)
        let n = min(frames, cap / channels)
        for i in 0..<n {
            dst[i * channels] = left[i]
            dst[i * channels + 1] = right[i]
        }
    }

    private static func zeroOutput(_ abl: UnsafeMutableAudioBufferListPointer) {
        for buffer in abl {
            if let raw = buffer.mData {
                memset(raw, 0, Int(buffer.mDataByteSize))
            }
        }
    }
}
