import Foundation
import AudioToolbox
import OSLog
import os

private let log = Logger(subsystem: "app.lurar.Lurar", category: "Resampler")

/// Real-time stereo sample-rate converter built on Core Audio's
/// `AudioConverter`. Used to bridge the Process Tap's variable native rate
/// (which follows the system default output and changes on track switches)
/// to the HAL Output AU's pinned client format — so a 44.1 → 96 kHz track
/// change reconfigures only this object instead of tearing the entire audio
/// chain down.
///
/// Threading: `process()` is called on the tap's audio thread; `configure()`
/// is called from the main thread when the tap rate changes. Both serialize
/// on a single `os_unfair_lock`. The lock is held for at most one converter
/// rebuild (sub-millisecond on first run, instant once the AU cache is warm),
/// which the audio thread can absorb without dropouts.
final class StereoResampler {
    let outputSampleRate: Double
    private(set) var inputSampleRate: Double = 0

    private var converter: AudioConverterRef?
    private var lock = os_unfair_lock()

    /// True when the configured input rate matches the output rate, so the
    /// converter can be bypassed. Read on the audio thread; `inputSampleRate`
    /// is only mutated from `configure()` under the lock, and an aligned
    /// 8-byte `Double` read is atomic on the platforms we target, so this
    /// gate is taken lock-free. A momentarily stale read across a rate change
    /// is harmless: it just routes one buffer through the (correct) slow path
    /// or vice versa for a single callback.
    private var isUnityRate: Bool {
        inputSampleRate > 0 && abs(inputSampleRate - outputSampleRate) < 0.5
    }

    /// Pre-allocated output scratch sized for the worst-case `tapSR → halSR`
    /// expansion (e.g. 44.1 → 192 kHz over a max 4096-frame tap callback ≈
    /// 17.4k frames). Caller-provided destinations would force callers to
    /// know the expansion ratio; keeping it here means the tap closure just
    /// hands input over and gets output back.
    private let outScratchLeft: UnsafeMutablePointer<Float>
    private let outScratchRight: UnsafeMutablePointer<Float>
    let outScratchCapacity: Int

    // Pre-allocated AudioBufferList backing storage — two non-interleaved
    // Float32 buffers. Sized once in init so the audio thread never
    // allocates.
    private let outputABL: UnsafeMutablePointer<AudioBufferList>
    private let outputABLStorage: UnsafeMutableRawPointer

    // Input staging — the `AudioConverterFillComplexBuffer` callback reads
    // these. Per-call set in `process()` before invoking the converter.
    private var pendingLeft: UnsafePointer<Float>?
    private var pendingRight: UnsafePointer<Float>?
    private var pendingFrames: Int = 0
    private var pendingConsumed: Bool = false

    init(outputSampleRate: Double, maxOutputFrames: Int = 32_768) {
        self.outputSampleRate = outputSampleRate
        outScratchLeft = .allocate(capacity: maxOutputFrames)
        outScratchRight = .allocate(capacity: maxOutputFrames)
        outScratchLeft.initialize(repeating: 0, count: maxOutputFrames)
        outScratchRight.initialize(repeating: 0, count: maxOutputFrames)
        outScratchCapacity = maxOutputFrames

        // AudioBufferList is a flexible C struct: one inline `AudioBuffer` plus
        // (mNumberBuffers - 1) trailing buffers. For stereo non-interleaved we
        // need 2 buffers, so allocate `sizeof(AudioBufferList) + sizeof(AudioBuffer)`.
        let ablSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        outputABLStorage = UnsafeMutableRawPointer.allocate(
            byteCount: ablSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        outputABL = outputABLStorage.assumingMemoryBound(to: AudioBufferList.self)
        outputABL.pointee.mNumberBuffers = 2
    }

    deinit {
        if let c = converter { AudioConverterDispose(c) }
        outScratchLeft.deinitialize(count: outScratchCapacity)
        outScratchRight.deinitialize(count: outScratchCapacity)
        outScratchLeft.deallocate()
        outScratchRight.deallocate()
        outputABLStorage.deallocate()
    }

    /// Build or rebuild the underlying converter for a new input rate. No-op
    /// if the rate already matches and a converter exists. Called from the
    /// main thread on tap-rate change.
    func configure(inputSampleRate: Double) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if inputSampleRate == self.inputSampleRate, converter != nil { return }
        if let c = converter {
            AudioConverterDispose(c)
            converter = nil
        }
        var inDesc = Self.stereoFloat32ASBD(sampleRate: inputSampleRate)
        var outDesc = Self.stereoFloat32ASBD(sampleRate: outputSampleRate)
        var newConverter: AudioConverterRef?
        let status = AudioConverterNew(&inDesc, &outDesc, &newConverter)
        if status != noErr || newConverter == nil {
            log.error("AudioConverterNew failed: \(status) (\(Int(inputSampleRate)) → \(Int(self.outputSampleRate)))")
            return
        }
        // High-quality (not mastering) polyphase SRC. Mastering complexity at
        // Max quality is the most CPU-intensive converter Core Audio offers and
        // it ran on every buffer — even silence — which was a major contributor
        // to high idle CPU (issue #101). For a real-time headphone-monitoring
        // path, Normal complexity at High quality is audibly transparent at a
        // fraction of the cost. (Most buffers now skip the converter entirely
        // via the 1:1 passthrough in `processIntoRingBuffer` anyway.)
        var quality: UInt32 = kAudioConverterQuality_High
        _ = AudioConverterSetProperty(
            newConverter!,
            kAudioConverterSampleRateConverterQuality,
            UInt32(MemoryLayout<UInt32>.size),
            &quality
        )
        var complexity: UInt32 = kAudioConverterSampleRateConverterComplexity_Normal
        _ = AudioConverterSetProperty(
            newConverter!,
            kAudioConverterSampleRateConverterComplexity,
            UInt32(MemoryLayout<UInt32>.size),
            &complexity
        )
        converter = newConverter
        self.inputSampleRate = inputSampleRate
        log.info("Resampler configured: \(Int(inputSampleRate)) → \(Int(self.outputSampleRate))")
    }

    /// Zero the converter's internal state. Useful after a long silence or
    /// when the upstream signal is known to be discontinuous (engine restart,
    /// device swap).
    func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let c = converter {
            AudioConverterReset(c)
        }
    }

    /// Resample `inFrames` of stereo input and write the result into
    /// `ringBuffer`. Audio thread. Returns the number of output frames
    /// actually produced (mostly informational — the ring buffer write has
    /// already happened).
    @discardableResult
    func processIntoRingBuffer(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frames: Int,
        ringBuffer: StereoFloatRingBuffer
    ) -> Int {
        // 1:1 fast path: when the tap rate already equals the output rate there
        // is nothing to convert. Skip the AudioConverter entirely and write the
        // (already-EQ'd) input straight through. With halSR now pinned to the
        // device's current nominal rate, this is the common steady-state path,
        // so the SRC cost on silence drops to zero.
        if isUnityRate {
            return ringBuffer.write(left: left, right: right, frames: frames)
        }
        let outFrames = process(
            inLeft: left,
            inRight: right,
            inFrames: frames
        )
        if outFrames > 0 {
            ringBuffer.write(left: outScratchLeft, right: outScratchRight, frames: outFrames)
        }
        return outFrames
    }

    /// Run the converter. Returns the count of frames written to the internal
    /// scratch (readable via `outScratchLeft` / `outScratchRight` until the
    /// next call).
    private func process(
        inLeft: UnsafePointer<Float>,
        inRight: UnsafePointer<Float>,
        inFrames: Int
    ) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let converter, inFrames > 0 else { return 0 }

        pendingLeft = inLeft
        pendingRight = inRight
        pendingFrames = inFrames
        pendingConsumed = false

        // Populate the pre-allocated output ABL with our scratch destination.
        let abp = UnsafeMutableAudioBufferListPointer(outputABL)
        let outByteSize = UInt32(outScratchCapacity * MemoryLayout<Float>.size)
        abp[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: outByteSize,
            mData: UnsafeMutableRawPointer(outScratchLeft)
        )
        abp[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: outByteSize,
            mData: UnsafeMutableRawPointer(outScratchRight)
        )

        // Request up to outScratchCapacity output packets. The framework will
        // call our input proc as needed; we hand it the full pending batch on
        // the first call and signal end-of-input on the second.
        var packets = UInt32(outScratchCapacity)
        let status = AudioConverterFillComplexBuffer(
            converter,
            Self.inputProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &packets,
            outputABL,
            nil
        )
        if status != noErr {
            // Soft-fail: HAL gets silence for this batch. Logging here would
            // spam the audio thread during e.g. a brief converter rebuild, so
            // stay quiet and let the next batch try again.
            return 0
        }
        return Int(packets)
    }

    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, inUserData in
        guard let inUserData else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        let me = Unmanaged<StereoResampler>.fromOpaque(inUserData).takeUnretainedValue()
        return me.handleInput(ioNumberDataPackets: ioNumberDataPackets, ioData: ioData)
    }

    private func handleInput(
        ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
        ioData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        if pendingConsumed {
            // Signal end of input for this `FillComplexBuffer` round so the
            // converter produces whatever output it can from buffered state.
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        pendingConsumed = true
        let frames = pendingFrames
        let byteSize = UInt32(frames * MemoryLayout<Float>.size)
        let abp = UnsafeMutableAudioBufferListPointer(ioData)
        // The framework hands us an ABL pre-sized for the input format's
        // buffer count (2 for non-interleaved stereo). We populate the buffer
        // descriptors to point at the caller's input data.
        abp[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: byteSize,
            mData: UnsafeMutableRawPointer(mutating: pendingLeft)
        )
        abp[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: byteSize,
            mData: UnsafeMutableRawPointer(mutating: pendingRight)
        )
        ioNumberDataPackets.pointee = UInt32(frames)
        return noErr
    }

    private static func stereoFloat32ASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        // Non-interleaved stereo float32. With kAudioFormatFlagIsNonInterleaved
        // set, mBytesPerPacket / mBytesPerFrame describe ONE channel's bytes —
        // each channel lives in its own AudioBuffer.
        let bytesPerSample = UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytesPerSample,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerSample,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
