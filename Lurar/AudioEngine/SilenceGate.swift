import Foundation
import Accelerate

/// Hysteresis gate that detects sustained digital silence on the tap input so
/// the engine can skip the heavy per-buffer DSP (crossfeed + the biquad
/// cascades) while nothing is playing. This is the follow-up to the idle-CPU
/// work in #101: with the engine on, the tap delivers buffers continuously
/// even when no app is producing sound, so without a gate the full EQ chain
/// runs forever on pure silence.
///
/// Threading: every method is called only from the tap IOProc (the audio
/// thread). All state is touched on that single thread, so no locking is
/// needed. `configure` is the one exception — it's invoked from the main
/// thread on a tap-rate change, but only ever between `start`/`stop` boundaries
/// or during a soft reconfigure where a one-callback-stale `holdFrames` is
/// harmless (it only shifts the idle-entry point by a few ms).
///
/// Why skipping is bit-safe: idle is entered only after `holdSeconds` of
/// *continuous* silence, during which the engine is still running the cascades
/// on the (silent) input. A stable biquad fed zeros decays its delay lines
/// toward zero, so by the time the gate trips, processing more zeros would
/// produce zeros anyway — skipping is therefore exact, not an approximation.
/// On the first non-silent buffer the gate releases immediately, so the
/// attack of resuming audio is never clipped.
final class SilenceGate {
    /// Peak magnitude at or below this (linear, ≈ −100 dBFS) counts as silent.
    /// Deliberately low: the tap mixdown of idle apps is exact 0.0, so this
    /// only ever trips on true silence, never on quiet musical passages.
    private let threshold: Float
    /// Require this much continuous silence before going idle, so inter-track
    /// gaps and quiet tails don't flap the gate — and so the IIR delay lines
    /// have time to decay to ~0 while we're still processing (see type doc).
    private let holdSeconds: Double

    private var holdFrames: Int
    private var silentFrameRun: Int = 0
    /// True once sustained silence has been observed. The caller skips the
    /// heavy DSP while this is set.
    private(set) var isIdle: Bool = false

    init(threshold: Float = 1e-5, holdSeconds: Double = 0.25, sampleRate: Double = 48_000) {
        self.threshold = threshold
        self.holdSeconds = holdSeconds
        self.holdFrames = max(1, Int(holdSeconds * sampleRate))
    }

    /// Recompute the hold length for a new tap sample rate. Main thread, on
    /// soft reconfigure.
    func configure(sampleRate: Double) {
        holdFrames = max(1, Int(holdSeconds * sampleRate))
    }

    /// Clear all state so a freshly started stream begins in the active
    /// (processing) state rather than inheriting a stale idle latch.
    func reset() {
        silentFrameRun = 0
        isIdle = false
    }

    /// Inspect one input block and return whether the engine should run the
    /// full DSP path for it. Returns `false` only once silence has persisted
    /// past the hold; any non-silent block releases the gate immediately and
    /// returns `true`.
    func shouldProcess(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) -> Bool {
        guard frames > 0 else { return !isIdle }
        var peakL: Float = 0
        var peakR: Float = 0
        vDSP_maxmgv(left, 1, &peakL, vDSP_Length(frames))
        vDSP_maxmgv(right, 1, &peakR, vDSP_Length(frames))

        if max(peakL, peakR) <= threshold {
            silentFrameRun &+= frames
            if silentFrameRun >= holdFrames { isIdle = true }
        } else {
            silentFrameRun = 0
            isIdle = false
        }
        return !isIdle
    }
}
