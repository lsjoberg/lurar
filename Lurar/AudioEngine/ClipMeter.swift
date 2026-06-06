import Foundation
import Accelerate
import os

/// Per-block peak meter + sticky-clip latch for the post-EQ output signal.
///
/// The audio thread calls `submit` once per IOProc callback with the
/// post-cascade (post-loudness, pre-output) L/R buffers. `vDSP_maxmgv` reads
/// the block peak per channel; that peak feeds an envelope follower with a
/// ~300 ms exponential release so the meter stays visible long enough for the
/// user to see momentary peaks. A separate sticky flag latches whenever any
/// sample's abs(x) >= 1.0 and clears 2 s after the last clip — that latency
/// keeps brief clips from disappearing between UI refreshes.
///
/// Publishing follows the same `os_unfair_lock_trylock` pattern as
/// `SpectrumAnalyzer`: the audio thread acquires the lock with trylock and
/// drops the whole submission on contention rather than blocking. Missing a
/// block costs one update of the peak envelope (~10 ms at 48k/512) — well
/// below visible. Real clips persist across many blocks, so the latch isn't
/// at risk of being missed in practice.
final class ClipMeter {
    /// Exponential release time constant on the peak envelope. Chosen so a
    /// transient peak stays above ~−10 dB of its initial value for several
    /// hundred milliseconds — long enough for the 30 Hz UI to render it.
    private static let releaseTimeConstant: Double = 0.3
    /// Sticky-clip hold: any clip latches the flag for this long.
    private static let clipHoldSeconds: Double = 2.0
    /// Floor used when converting linear peak to dBFS. Anything below this
    /// reads as the bottom of the meter scale.
    private static let dbFloor: Float = -120

    private var lock = os_unfair_lock()
    private(set) var sampleRate: Double = 48_000

    // Peak envelope state — read and written only under the lock (which the
    // audio thread holds via trylock).
    private var peakL: Float = 0
    private var peakR: Float = 0

    // Sticky-clip latch state.
    private var clippedLatched: Bool = false
    private var framesSinceClip: UInt64 = .max

    // Published snapshots for the main thread.
    private var publishedPeakDBL: Float = ClipMeter.dbFloor
    private var publishedPeakDBR: Float = ClipMeter.dbFloor
    private var publishedClipped: Bool = false
    // Monotonic count of frames the audio thread has pushed through `submit`.
    // Lets a main-thread poller tell "tap still delivering buffers" apart from
    // "IOProc stopped" — when playback pauses, some setups keep the tap firing
    // with silence (peak decays to the floor) while others stop it entirely
    // (peak freezes at its last value). Reading whether this advanced between
    // polls disambiguates the frozen-peak case. Wraps only after ~6M years at
    // 48 kHz, so treat it as effectively unbounded.
    private var publishedFramesProcessed: UInt64 = 0

    struct Snapshot {
        var peakDBL: Float
        var peakDBR: Float
        var clipped: Bool
        var framesProcessed: UInt64
    }

    func configure(sampleRate: Double) {
        os_unfair_lock_lock(&lock)
        self.sampleRate = sampleRate
        os_unfair_lock_unlock(&lock)
    }

    /// Reset both audio-thread envelope state and the published snapshot.
    /// Called on engine restart so a fresh stream doesn't show a decaying tail
    /// from the previous one.
    func reset() {
        os_unfair_lock_lock(&lock)
        peakL = 0
        peakR = 0
        clippedLatched = false
        framesSinceClip = .max
        publishedPeakDBL = ClipMeter.dbFloor
        publishedPeakDBR = ClipMeter.dbFloor
        publishedClipped = false
        publishedFramesProcessed = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Audio-thread entry. No allocations: vDSP block peak + a handful of
    /// scalar math ops + an atomic publish under trylock. Dropped on
    /// contention with a UI snapshot — the next callback will publish fresh
    /// values, which is indistinguishable from normal cadence at 30 Hz.
    func submit(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }

        var blockPeakL: Float = 0
        var blockPeakR: Float = 0
        vDSP_maxmgv(left, 1, &blockPeakL, vDSP_Length(frames))
        vDSP_maxmgv(right, 1, &blockPeakR, vDSP_Length(frames))

        let sr = sampleRate
        let blockSeconds = Double(frames) / sr
        // exp(-Δt/τ) for the per-block envelope decay.
        let decay = Float(exp(-blockSeconds / Self.releaseTimeConstant))

        peakL = max(blockPeakL, peakL * decay)
        peakR = max(blockPeakR, peakR * decay)

        let blockClipped = (blockPeakL >= 1.0) || (blockPeakR >= 1.0)
        if blockClipped {
            clippedLatched = true
            framesSinceClip = 0
        } else if clippedLatched {
            framesSinceClip &+= UInt64(frames)
            let holdFrames = UInt64(Self.clipHoldSeconds * sr)
            if framesSinceClip >= holdFrames {
                clippedLatched = false
            }
        }

        publishedPeakDBL = Self.dbFromLinear(peakL)
        publishedPeakDBR = Self.dbFromLinear(peakR)
        publishedClipped = clippedLatched
        publishedFramesProcessed &+= UInt64(frames)
    }

    /// Main-thread entry: always succeeds, returns the most recently
    /// published values.
    func snapshot() -> Snapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Snapshot(peakDBL: publishedPeakDBL,
                        peakDBR: publishedPeakDBR,
                        clipped: publishedClipped,
                        framesProcessed: publishedFramesProcessed)
    }

    /// Clear the sticky-clip latch. Called when the user clicks the meters.
    func clearClip() {
        os_unfair_lock_lock(&lock)
        clippedLatched = false
        framesSinceClip = .max
        publishedClipped = false
        os_unfair_lock_unlock(&lock)
    }

    private static func dbFromLinear(_ v: Float) -> Float {
        guard v > 0 else { return dbFloor }
        let db = 20.0 * log10(v)
        return max(db, dbFloor)
    }
}
