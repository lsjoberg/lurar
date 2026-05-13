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
    static let sectionCount = 4

    private let cascadeL: BiquadCascade
    private let cascadeR: BiquadCascade

    private var lock = os_unfair_lock()
    /// Flat coefficient buffer: 5 doubles per section, contiguous (b0,b1,b2,a1,a2 × N).
    private var pendingCoefficients: [Double]
    private var coefficientsDirty: Bool = false
    private var pendingPreampLinear: Float = 1.0
    /// Snapshot of preamp the audio thread is currently using; mutated only there.
    private var preampLinear: Float = 1.0

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
    }

    // MARK: - Main-thread API

    /// Configure all bands + preamp from a preset for the given sample rate. Coefficients
    /// are pushed atomically; the next audio callback will pick them up.
    func configure(preset: EQPreset, sampleRate: Double) {
        self.sampleRate = sampleRate
        var flat: [Double] = []
        flat.reserveCapacity(5 * EQProcessor.sectionCount)
        for i in 0..<EQProcessor.sectionCount {
            if i < preset.bands.count {
                let b = preset.bands[i]
                let c = BiquadCoefficients.make(type: b.type, frequency: b.frequency, gainDB: b.gain, q: b.q, sampleRate: sampleRate)
                flat.append(contentsOf: [c.0, c.1, c.2, c.3, c.4])
            } else {
                let c = BiquadCoefficients.identity
                flat.append(contentsOf: [c.0, c.1, c.2, c.3, c.4])
            }
        }
        publish(coefficients: flat, preampDB: preset.preamp)
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

    // MARK: - Audio-thread entry

    /// Apply preamp + biquad cascades in place on left/right Float32 buffers. Picks up
    /// any pending parameter changes via `trylock` so the audio thread never blocks.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        if os_unfair_lock_trylock(&lock) {
            if coefficientsDirty {
                cascadeL.setCoefficients(pendingCoefficients)
                cascadeR.setCoefficients(pendingCoefficients)
                coefficientsDirty = false
            }
            preampLinear = pendingPreampLinear
            os_unfair_lock_unlock(&lock)
        }

        var gain = preampLinear
        if gain != 1.0 {
            vDSP_vsmul(left, 1, &gain, left, 1, vDSP_Length(frames))
            vDSP_vsmul(right, 1, &gain, right, 1, vDSP_Length(frames))
        }
        cascadeL.process(left, frames: frames)
        cascadeR.process(right, frames: frames)
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
}
