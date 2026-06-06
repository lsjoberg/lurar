import Foundation
import os

/// Per-output linear gain envelope, applied in place on the audio thread.
///
/// In the old two-thread pipeline this lived inside the ring buffer's read path —
/// the fade-out before a teardown, the fade-in after a restart, the duck across a
/// device-rate change, and the A/B mute all rode the reader's gain ramp. The
/// single-IOProc in-place pipeline has no reader/writer handoff to host that, so the
/// engine drives this object directly and the tap IOProc applies it as the final DSP
/// stage, just before the EQ'd buffer is copied into the output device.
///
/// `setTarget` is safe to call from any thread; `apply` runs on the audio thread.
/// Both serialize on an `os_unfair_lock` held only for the trivial envelope math —
/// the same discipline the ring buffer used. A unity, un-ramping envelope short-
/// circuits with no per-sample work.
final class OutputGainRamp {
    private var lock = os_unfair_lock()
    private var currentGain: Float = 1.0
    private var targetGain: Float = 1.0
    private var rampStep: Float = 0
    private var rampFramesRemaining: Int = 0

    /// Schedule a linear ramp toward `target` over the next `rampFrames` frames
    /// actually processed. `target = 0` fades out before a teardown, `target = 1`
    /// fades back in. `rampFrames = 0` snaps immediately. Safe from any thread.
    func setTarget(_ target: Float, rampFrames: Int) {
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

    /// Apply the envelope to `frames` of stereo audio in place. Audio thread.
    /// Advances the ramp by exactly the frames scaled, so a fade always completes
    /// over its scheduled duration regardless of buffer size.
    func apply(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var g = currentGain
        let step = rampStep
        let target = targetGain
        var remaining = rampFramesRemaining
        if remaining == 0 && g == 1.0 { return } // unity passthrough fast path
        for i in 0..<frames {
            left[i] *= g
            right[i] *= g
            if remaining > 0 {
                g += step
                remaining -= 1
                if remaining == 0 { g = target }
            }
        }
        currentGain = g
        rampFramesRemaining = remaining
    }
}
