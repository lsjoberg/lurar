import Foundation
import Accelerate
import os

/// Owns L+R biquad cascades and a preamp scalar. The audio thread calls `process` on
/// every input callback; the main thread calls `configure`, `updateBand`, `setPreamp`
/// to publish parameter changes.
///
/// Parameter passing: pending coefficients live behind an `os_unfair_lock` that the
/// audio thread acquires with `trylock`. If contended (UI is mid-update), the audio
/// thread keeps using the previous coefficients for one callback — worst case ~10 ms
/// of latency on a slider drag, which is below the threshold of perception.
final class EQProcessor {
    static let sectionCount = 10
    /// Sections in the loudness-compensation cascade applied after the main EQ.
    static let loudnessSectionCount = LoudnessContour.sectionCount

    private let cascadeL: BiquadCascade
    private let cascadeR: BiquadCascade
    /// Loudness-compensation cascade applied AFTER the main EQ. Skipped
    /// structurally (cascade.process never called) when loudnessActive == false.
    private let cascadeLoudL: BiquadCascade
    private let cascadeLoudR: BiquadCascade

    private var lock = os_unfair_lock()
    /// Flat coefficient buffer: 5 doubles per section, contiguous (b0,b1,b2,a1,a2 × N).
    private var pendingCoefficients: [Double]
    private var coefficientsDirty: Bool = false
    private var pendingPreampLinear: Float = 1.0
    /// Snapshot of preamp the audio thread is currently using; mutated only there.
    private var preampLinear: Float = 1.0

    /// Loudness compensation. Same trylock/dirty-flag publishing discipline as
    /// the main EQ — main thread mutates `pending*` under the lock; audio
    /// thread snapshots them inside `trylock`. The `loudnessActive` flag
    /// gates `process` calls on the audio thread so an offset of 0 means a
    /// STRUCTURAL bypass (the cascade doesn't run), not just flat numerics.
    private var pendingLoudnessCoefficients: [Double]
    private var loudnessCoefficientsDirty: Bool = false
    private var pendingLoudnessActive: Bool = false
    private var loudnessActive: Bool = false
    /// Headroom attenuation (linear, ≤ 1.0) applied alongside `preampLinear`
    /// so the boosted bass/treble can't push the signal above 0 dBFS. 1.0
    /// when loudness is off — multiplied unconditionally on the audio thread
    /// so slot mode picks it up for free.
    private var pendingLoudnessHeadroomLinear: Float = 1.0
    private var loudnessHeadroomLinear: Float = 1.0
    /// Cached so configure() can re-fit at a new sample rate. Main thread only.
    private var currentLoudnessOffsetDB: Float = 0

    /// A/B slot mode: when non-empty, the audio thread reads coefficients and
    /// preamp from these per-slot buffers instead of the regular `pendingCoefficients`
    /// path. The main thread populates them via `loadSlots(...)` and flips the
    /// active slot via `setActiveSlot(...)`.
    private var slotCoefficients: [[Double]] = []
    private var slotPreampsLinear: [Float] = []
    private var pendingActiveSlot: Int = 0
    /// Sentinel −1 forces the audio thread to apply slot 0 on the first callback
    /// after `loadSlots(...)`, even though `pendingActiveSlot` is already 0.
    private var appliedActiveSlot: Int = -1

    /// Post-cascade output multiplier (0 = silent, 1 = normal). Used by the
    /// comparison flow to insert a brief silence around blind-trial slot swaps
    /// so the swap itself is inaudible. Applied AFTER the biquad cascades so
    /// the IIR delay lines keep running on real audio — unmute resumes
    /// artifact-free.
    private var pendingMuteLinear: Float = 1.0
    private var muteLinear: Float = 1.0

    private(set) var sampleRate: Double = 48_000

    init() {
        // Build initial passthrough cascades so the audio thread can run even before the
        // first configure() call lands.
        var identityFlat: [Double] = []
        identityFlat.reserveCapacity(5 * EQProcessor.sectionCount)
        for _ in 0..<EQProcessor.sectionCount {
            let c = BiquadCoefficients.identity
            identityFlat.append(contentsOf: [c.0, c.1, c.2, c.3, c.4])
        }
        self.cascadeL = BiquadCascade(sectionCount: EQProcessor.sectionCount, initialCoefficients: identityFlat)
        self.cascadeR = BiquadCascade(sectionCount: EQProcessor.sectionCount, initialCoefficients: identityFlat)
        self.pendingCoefficients = identityFlat

        let identityLoud = LoudnessContour.identityCoefficients
        self.cascadeLoudL = BiquadCascade(sectionCount: EQProcessor.loudnessSectionCount, initialCoefficients: identityLoud)
        self.cascadeLoudR = BiquadCascade(sectionCount: EQProcessor.loudnessSectionCount, initialCoefficients: identityLoud)
        self.pendingLoudnessCoefficients = identityLoud
    }

    // MARK: - Main-thread API

    /// Configure all bands + preamp from a preset for the given sample rate. Coefficients
    /// are pushed atomically; the next audio callback will pick them up.
    func configure(preset: EQPreset, sampleRate: Double) {
        self.sampleRate = sampleRate
        let flat = Self.flatCoefficients(for: preset, sampleRate: sampleRate)
        publish(coefficients: flat, preampDB: preset.preamp)
        // Sample rate may have changed; re-fit the loudness cascade so its
        // biquad centre frequencies stay correct relative to the new Nyquist.
        if abs(currentLoudnessOffsetDB) >= 0.01 {
            publishLoudness(offsetDB: currentLoudnessOffsetDB)
        }
    }

    /// Recompute a single band's coefficients and republish. Cheap; called on slider drag.
    func updateBand(index: Int, band: EQBand) {
        guard (0..<EQProcessor.sectionCount).contains(index) else { return }
        os_unfair_lock_lock(&lock)
        let base = index * 5
        let c = BiquadCoefficients.make(type: band.type, frequency: band.frequency, gainDB: band.gain, q: band.q, sampleRate: sampleRate)
        pendingCoefficients[base + 0] = c.0
        pendingCoefficients[base + 1] = c.1
        pendingCoefficients[base + 2] = c.2
        pendingCoefficients[base + 3] = c.3
        pendingCoefficients[base + 4] = c.4
        coefficientsDirty = true
        os_unfair_lock_unlock(&lock)
    }

    func setPreamp(dB: Float) {
        let linear = pow(10.0, dB / 20.0)
        os_unfair_lock_lock(&lock)
        pendingPreampLinear = linear
        os_unfair_lock_unlock(&lock)
    }

    /// Recompute the loudness cascade for the given offset (≤ 0 dB, expected
    /// in [−40, 0]) and publish coefficients + active flag + headroom
    /// attenuation in a single lock acquisition. Audio thread picks the new
    /// state up on its next `trylock`-successful callback.
    ///
    /// When |offsetDB| < 0.01 this publishes an inactive state — the audio
    /// thread will reset the loudness cascades' delay lines and then skip
    /// `process` calls entirely, so an offset of 0 is bit-identical to the
    /// pre-loudness signal path (modulo whatever was in the delay lines for
    /// one callback after deactivation, hence the reset).
    func publishLoudness(offsetDB: Float) {
        currentLoudnessOffsetDB = offsetDB
        let active = abs(Double(offsetDB)) >= 0.01
        let coeffs: [Double]
        let headroomLinear: Float
        if active {
            let fit = LoudnessContour.fitBiquads(offsetDB: Double(offsetDB), sampleRate: sampleRate)
            coeffs = fit.coefficients
            headroomLinear = Float(pow(10.0, -fit.headroomDB / 20.0))
        } else {
            coeffs = LoudnessContour.identityCoefficients
            headroomLinear = 1.0
        }

        os_unfair_lock_lock(&lock)
        pendingLoudnessCoefficients = coeffs
        loudnessCoefficientsDirty = true
        pendingLoudnessActive = active
        pendingLoudnessHeadroomLinear = headroomLinear
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Audio-thread entry

    /// Apply preamp + biquad cascades in place on left/right Float32 buffers. Picks up
    /// any pending parameter changes via `trylock` so the audio thread never blocks.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if os_unfair_lock_trylock(&lock) {
            if !slotCoefficients.isEmpty {
                // A/B slot mode: switch coefficients + preamp if the active slot
                // changed (or on first apply after loadSlots, signalled by the −1
                // sentinel in appliedActiveSlot). The IIR delay line is preserved
                // across the swap so the transition is click-free for non-pathological
                // preset pairs — same property the editor's preset-switch already relies on.
                if pendingActiveSlot != appliedActiveSlot {
                    let coeffs = slotCoefficients[pendingActiveSlot]
                    cascadeL.setCoefficients(coeffs)
                    cascadeR.setCoefficients(coeffs)
                    preampLinear = slotPreampsLinear[pendingActiveSlot]
                    appliedActiveSlot = pendingActiveSlot
                }
                coefficientsDirty = false
            } else {
                if coefficientsDirty {
                    cascadeL.setCoefficients(pendingCoefficients)
                    cascadeR.setCoefficients(pendingCoefficients)
                    coefficientsDirty = false
                }
                preampLinear = pendingPreampLinear
            }
            // Loudness cascade pickup. Coefficient swap first (delay line is
            // preserved across the swap, same property the main cascade
            // relies on); then the active flag transition. Deactivation
            // resets delay-line state so the next activation can't replay
            // stale IIR history.
            if loudnessCoefficientsDirty {
                cascadeLoudL.setCoefficients(pendingLoudnessCoefficients)
                cascadeLoudR.setCoefficients(pendingLoudnessCoefficients)
                loudnessCoefficientsDirty = false
            }
            if pendingLoudnessActive != loudnessActive {
                if !pendingLoudnessActive {
                    cascadeLoudL.reset()
                    cascadeLoudR.reset()
                }
                loudnessActive = pendingLoudnessActive
            }
            loudnessHeadroomLinear = pendingLoudnessHeadroomLinear
            muteLinear = pendingMuteLinear
            os_unfair_lock_unlock(&lock)
        }

        var gain = preampLinear * loudnessHeadroomLinear
        if gain != 1.0 {
            vDSP_vsmul(left, 1, &gain, left, 1, vDSP_Length(frames))
            vDSP_vsmul(right, 1, &gain, right, 1, vDSP_Length(frames))
        }
        cascadeL.process(left, frames: frames)
        cascadeR.process(right, frames: frames)

        // Loudness compensation runs after the main EQ so the user's preset
        // EQs the headphone, and the loudness curve EQs the listener's ear
        // response — two independent corrections in series. Gated structurally
        // by `loudnessActive`: at offset 0 the cascade doesn't run at all.
        if loudnessActive {
            cascadeLoudL.process(left, frames: frames)
            cascadeLoudR.process(right, frames: frames)
        }

        // Post-cascade mute. Scaling here (rather than zeroing the pre-cascade
        // gain) means the IIR delay lines keep running on real audio, so unmute
        // is glitch-free — the cascades have been computing as usual the whole time.
        if muteLinear != 1.0 {
            var m = muteLinear
            vDSP_vsmul(left, 1, &m, left, 1, vDSP_Length(frames))
            vDSP_vsmul(right, 1, &m, right, 1, vDSP_Length(frames))
        }
    }

    // MARK: - Helpers

    private func publish(coefficients: [Double], preampDB: Float) {
        let linear = pow(10.0, preampDB / 20.0)
        os_unfair_lock_lock(&lock)
        pendingCoefficients = coefficients
        coefficientsDirty = true
        pendingPreampLinear = linear
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - A/B comparison slot mode

    enum Slot: Int { case a = 0, b = 1 }

    /// True when `loadSlots(...)` has been called and `exitSlotMode()` has not.
    var isInSlotMode: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return !slotCoefficients.isEmpty
    }

    /// Pre-compute both presets' coefficients on the main thread and stash them
    /// behind the lock. `extraGainDB*` is folded into each slot's preamp so the
    /// audio-thread switch is a single scalar copy — the loudness-match offset
    /// costs nothing per callback.
    func loadSlots(
        presetA: EQPreset, presetB: EQPreset,
        sampleRate: Double,
        extraGainDBA: Float, extraGainDBB: Float
    ) {
        self.sampleRate = sampleRate
        let coeffA = Self.flatCoefficients(for: presetA, sampleRate: sampleRate)
        let coeffB = Self.flatCoefficients(for: presetB, sampleRate: sampleRate)
        let preampA = pow(10.0, (presetA.preamp + extraGainDBA) / 20.0)
        let preampB = pow(10.0, (presetB.preamp + extraGainDBB) / 20.0)

        os_unfair_lock_lock(&lock)
        slotCoefficients = [coeffA, coeffB]
        slotPreampsLinear = [preampA, preampB]
        pendingActiveSlot = 0
        appliedActiveSlot = -1   // force the audio thread to apply slot 0 next callback
        coefficientsDirty = false // suppress any stale regular-path publish
        os_unfair_lock_unlock(&lock)
    }

    /// Flip the active slot. Audio thread picks it up on the next callback
    /// (worst case ~one buffer of latency, ≈10 ms at 48 kHz / 512 frames).
    func setActiveSlot(_ slot: Slot) {
        os_unfair_lock_lock(&lock)
        pendingActiveSlot = slot.rawValue
        os_unfair_lock_unlock(&lock)
    }

    /// Leave slot mode. The cascades retain whichever slot was last applied
    /// until the engine publishes a new preset via `configure(...)`. Callers
    /// should immediately follow this with `configure(...)` to put the engine
    /// back into a coherent "single-preset" state.
    func exitSlotMode() {
        os_unfair_lock_lock(&lock)
        slotCoefficients = []
        slotPreampsLinear = []
        pendingActiveSlot = 0
        appliedActiveSlot = -1
        // Defensive: if a comparison session was mid-trial when something
        // exited slot mode externally, unmute so we don't leave the user with
        // silence.
        pendingMuteLinear = 1.0
        os_unfair_lock_unlock(&lock)
    }

    /// Set post-cascade mute. `muted = true` produces silence on the next
    /// audio callback (worst-case ~one buffer of latency); `false` resumes.
    func setMute(_ muted: Bool) {
        os_unfair_lock_lock(&lock)
        pendingMuteLinear = muted ? 0.0 : 1.0
        os_unfair_lock_unlock(&lock)
    }

    /// Build the flat coefficient buffer the cascade expects, padding short
    /// presets with identity sections. Pure compute, no lock.
    private static func flatCoefficients(for preset: EQPreset, sampleRate: Double) -> [Double] {
        var flat: [Double] = []
        flat.reserveCapacity(5 * sectionCount)
        for i in 0..<sectionCount {
            let c: (Double, Double, Double, Double, Double)
            if i < preset.bands.count {
                let b = preset.bands[i]
                c = BiquadCoefficients.make(type: b.type, frequency: b.frequency, gainDB: b.gain, q: b.q, sampleRate: sampleRate)
            } else {
                c = BiquadCoefficients.identity
            }
            flat.append(contentsOf: [c.0, c.1, c.2, c.3, c.4])
        }
        return flat
    }
}
