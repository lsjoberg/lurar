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
        }

        if n < frames {
            ldst.advanced(by: n).update(repeating: 0, count: frames - n)
            rdst.advanced(by: n).update(repeating: 0, count: frames - n)
        }
        return n
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        writeIdx = 0
        readIdx = 0
    }

    var availableFrames: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return writeIdx - readIdx
    }
}
