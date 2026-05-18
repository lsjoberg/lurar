import Foundation
import os

/// Lock-protected SPSC ring buffer for non-interleaved stereo Float32 audio. The tap thread
/// writes; the HAL Output render callback reads. An os_unfair_lock is used because pure atomic
/// ordering for a wrap-around index pair in Swift requires more ceremony than the latency
/// difference is worth at typical audio buffer sizes (~5 ms).
final class StereoFloatRingBuffer {
    private var left: UnsafeMutablePointer<Float>
    private var right: UnsafeMutablePointer<Float>
    let capacity: Int
    private var writeIdx: Int = 0
    private var readIdx: Int = 0
    private var lock = os_unfair_lock()

    // Per-read gain envelope. The reader (HAL render callback) multiplies each
    // sample by `currentGain`, which linearly ramps toward `targetGain` over
    // `rampFramesRemaining` more *actually-consumed* frames. The ramp only
    // advances on real reads — padding zeros don't move it — so that a fade-in
    // armed during the engine restart waits for fresh samples to land in the
    // ring before scaling them, rather than burning the ramp on the empty
    // post-teardown window.
    private var currentGain: Float = 1.0
    private var targetGain: Float = 1.0
    private var rampStep: Float = 0
    private var rampFramesRemaining: Int = 0

    /// Diagnostic counter — incremented every time `read()` is short of
    /// frames (writer fell behind, reader hit the empty/wrap edge of the
    /// buffer and got zero-padded). Cleared by `resetUnderrunCount()`.
    /// Read from the main thread; written from the audio thread under the
    /// existing lock.
    private(set) var underrunReads: Int = 0
    /// Diagnostic: the smallest non-zero amount by which a `read()` fell
    /// short, in frames. Tells us "how bad was the worst underrun" so we
    /// can tell a single-frame edge case apart from a real drain.
    private(set) var worstUnderrunShortfall: Int = 0

    init(capacityFrames: Int) {
        self.capacity = capacityFrames
        left = .allocate(capacity: capacityFrames)
        right = .allocate(capacity: capacityFrames)
        left.initialize(repeating: 0, count: capacityFrames)
        right.initialize(repeating: 0, count: capacityFrames)
    }

    deinit {
        left.deinitialize(count: capacity)
        right.deinitialize(count: capacity)
        left.deallocate()
        right.deallocate()
    }

    @discardableResult
    func write(left lsrc: UnsafePointer<Float>, right rsrc: UnsafePointer<Float>, frames: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let available = capacity - (writeIdx - readIdx)
        let n = min(available, frames)
        if n <= 0 { return 0 }

        let w = writeIdx % capacity
        if w + n <= capacity {
            left.advanced(by: w).update(from: lsrc, count: n)
            right.advanced(by: w).update(from: rsrc, count: n)
        } else {
            let first = capacity - w
            left.advanced(by: w).update(from: lsrc, count: first)
            right.advanced(by: w).update(from: rsrc, count: first)
            left.update(from: lsrc.advanced(by: first), count: n - first)
            right.update(from: rsrc.advanced(by: first), count: n - first)
        }
        writeIdx += n
        return n
    }

    /// Reads up to `frames` frames into `ldst` / `rdst`. If the buffer is short, the tail is
    /// zero-padded so the consumer gets a full frames-worth of audio (a brief glitch is better
    /// than passing garbage uninitialized memory to the audio output).
    @discardableResult
    func read(left ldst: UnsafeMutablePointer<Float>, right rdst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let available = writeIdx - readIdx
        let n = min(available, frames)

        if n > 0 {
            let r = readIdx % capacity
            if r + n <= capacity {
                ldst.update(from: left.advanced(by: r), count: n)
                rdst.update(from: right.advanced(by: r), count: n)
            } else {
                let first = capacity - r
                ldst.update(from: left.advanced(by: r), count: first)
                rdst.update(from: right.advanced(by: r), count: first)
                ldst.advanced(by: first).update(from: left, count: n - first)
                rdst.advanced(by: first).update(from: right, count: n - first)
            }
            readIdx += n
            applyGainEnvelope(left: ldst, right: rdst, frames: n)
        }

        if n < frames {
            ldst.advanced(by: n).update(repeating: 0, count: frames - n)
            rdst.advanced(by: n).update(repeating: 0, count: frames - n)
            let shortfall = frames - n
            underrunReads &+= 1
            if shortfall > worstUnderrunShortfall {
                worstUnderrunShortfall = shortfall
            }
        }
        return n
    }

    /// Clear the underrun counters. Main thread.
    func resetUnderrunCount() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        underrunReads = 0
        worstUnderrunShortfall = 0
    }

    /// Snapshot `(reads, worstShortfallFrames, availableFrames)` for
    /// periodic diagnostic logging. Main thread.
    func underrunSnapshot() -> (reads: Int, worstShortfall: Int, available: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (underrunReads, worstUnderrunShortfall, writeIdx - readIdx)
    }

    /// Schedule a linear gain ramp toward `target` over the next `rampFrames`
    /// frames actually read out of the buffer. Use `target = 0` to fade out
    /// before a teardown, `target = 1` to fade back in after a restart. A
    /// ramp of 0 frames snaps the gain immediately. Safe to call from any
    /// thread.
    func setOutputGain(_ target: Float, rampFrames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        targetGain = target
        if currentGain == target {
            rampStep = 0
            rampFramesRemaining = 0
            return
        }
        let frames = max(0, rampFrames)
        if frames == 0 {
            currentGain = target
            rampStep = 0
            rampFramesRemaining = 0
        } else {
            rampStep = (target - currentGain) / Float(frames)
            rampFramesRemaining = frames
        }
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        writeIdx = 0
        readIdx = 0
    }

    // Called with `lock` held. Advances the gain ramp across the `n` real
    // samples just copied into the destination buffers and scales them in
    // place. Padding zeros (n < frames case) are skipped — see the field
    // comment above for why.
    private func applyGainEnvelope(left ldst: UnsafeMutablePointer<Float>,
                                   right rdst: UnsafeMutablePointer<Float>,
                                   frames n: Int) {
        var g = currentGain
        let step = rampStep
        let target = targetGain
        var remaining = rampFramesRemaining
        if remaining == 0 && g == 1.0 { return } // unity passthrough fast path
        for i in 0..<n {
            ldst[i] *= g
            rdst[i] *= g
            if remaining > 0 {
                g += step
                remaining -= 1
                if remaining == 0 { g = target }
            }
        }
        currentGain = g
        rampFramesRemaining = remaining
    }

    var availableFrames: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return writeIdx - readIdx
    }
}
