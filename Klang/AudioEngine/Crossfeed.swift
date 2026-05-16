import Foundation
import Accelerate
import os

/// Bauer-style headphone crossfeed: each ear gets a delayed, lowpassed copy of the
/// opposite channel mixed in, simulating the acoustic path that exists on speakers
/// but is missing on headphones. Pulls hard-panned content out of the listener's
/// head and into a more speaker-like soundstage.
///
/// Two parameters (mutable from the main thread, picked up by the audio thread via
/// `trylock`):
///   - `intensity` 0...1 — mix amount of the cross-fed signal
///   - `cutoffHz` — 1-pole LPF corner applied to the cross signal (head shadow)
///
/// At intensity 0 this is bit-exact passthrough.
final class Crossfeed {
    /// Interaural time difference (~250 µs) realized as a small integer-sample delay
    /// at the current sample rate. 48 kHz → 12 samples, 96 kHz → 24 samples.
    private static let itdSeconds: Double = 0.000_25

    private var sampleRate: Double = 48_000
    private var delaySamples: Int = 12

    // Delay lines for the cross paths (L into R, R into L). Sized for the worst-case
    // sample rate we expect (192 kHz → 48 samples) plus slack; allocated once.
    private var delayL: [Float] = Array(repeating: 0, count: 64)
    private var delayR: [Float] = Array(repeating: 0, count: 64)
    private var delayIdxL: Int = 0
    private var delayIdxR: Int = 0

    // 1-pole lowpass state for the cross signal (one per direction).
    private var lpStateL: Float = 0
    private var lpStateR: Float = 0
    private var lpAlpha: Float = 0.1

    // Active parameters (audio thread reads these directly).
    private var activeIntensity: Float = 0
    private var activeCutoff: Float = 700

    // Pending parameters (UI writes under lock; audio thread picks up via trylock).
    private var lock = os_unfair_lock()
    private var pendingIntensity: Float = 0
    private var pendingCutoff: Float = 700
    private var pendingDirty: Bool = false

    /// Update DSP coefficients for the engine's current sample rate. Safe to call
    /// from the main thread; audio thread will pick up the new delay/cutoff on the
    /// next callback.
    func configure(sampleRate: Double) {
        os_unfair_lock_lock(&lock)
        self.sampleRate = sampleRate
        self.delaySamples = max(1, min(delayL.count - 1,
                                       Int((Crossfeed.itdSeconds * sampleRate).rounded())))
        self.lpAlpha = onePoleAlpha(cutoff: activeCutoff, sampleRate: sampleRate)
        pendingDirty = true
        os_unfair_lock_unlock(&lock)
    }

    func setIntensity(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        os_unfair_lock_lock(&lock)
        pendingIntensity = clamped
        pendingDirty = true
        os_unfair_lock_unlock(&lock)
    }

    func setCutoff(_ hz: Float) {
        let clamped = min(max(hz, 200), 2000)
        os_unfair_lock_lock(&lock)
        pendingCutoff = clamped
        pendingDirty = true
        os_unfair_lock_unlock(&lock)
    }

    /// Apply crossfeed in place. At intensity 0 this is a no-op (and skips the
    /// per-sample loop entirely).
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if os_unfair_lock_trylock(&lock) {
            if pendingDirty {
                activeIntensity = pendingIntensity
                activeCutoff = pendingCutoff
                lpAlpha = onePoleAlpha(cutoff: activeCutoff, sampleRate: sampleRate)
                pendingDirty = false
            }
            os_unfair_lock_unlock(&lock)
        }

        let mix = activeIntensity
        if mix <= 0 { return }

        // Headroom trim: scale both direct and crossed paths so a mono-summed worst
        // case (in-phase content, LPF passband gain ≈ 1) doesn't blow past unity.
        // At intensity 1 this is roughly -3.5 dB on the direct path.
        let trim: Float = 1.0 / (1.0 + 0.5 * mix)
        let alpha = lpAlpha
        let n = delaySamples
        let cap = delayL.count

        delayL.withUnsafeMutableBufferPointer { dL in
            delayR.withUnsafeMutableBufferPointer { dR in
                var idxL = delayIdxL
                var idxR = delayIdxR
                var lpL = lpStateL
                var lpR = lpStateR

                for i in 0..<frames {
                    let inL = left[i]
                    let inR = right[i]

                    // Write current samples into the delay lines.
                    dL[idxL] = inL
                    dR[idxR] = inR

                    // Read the opposite channel n samples in the past.
                    let tapL = dL[(idxL + cap - n) % cap]
                    let tapR = dR[(idxR + cap - n) % cap]

                    // 1-pole LPF on each cross signal (head-shadow approximation).
                    lpL += alpha * (tapL - lpL)
                    lpR += alpha * (tapR - lpR)

                    left[i] = trim * (inL + mix * lpR)
                    right[i] = trim * (inR + mix * lpL)

                    idxL = (idxL + 1) % cap
                    idxR = (idxR + 1) % cap
                }

                delayIdxL = idxL
                delayIdxR = idxR
                lpStateL = lpL
                lpStateR = lpR
            }
        }
    }

    func reset() {
        for i in 0..<delayL.count { delayL[i] = 0; delayR[i] = 0 }
        delayIdxL = 0
        delayIdxR = 0
        lpStateL = 0
        lpStateR = 0
    }

    private func onePoleAlpha(cutoff: Float, sampleRate: Double) -> Float {
        let dt = 1.0 / Float(sampleRate)
        let rc = 1.0 / (2.0 * .pi * cutoff)
        return dt / (rc + dt)
    }
}
