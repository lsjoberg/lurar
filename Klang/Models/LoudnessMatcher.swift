import Foundation

/// Static, deterministic loudness matching for A/B preset comparison.
///
/// We integrate each preset's closed-form magnitude response on a log-spaced
/// grid from 20 Hz – 20 kHz and pick the per-slot attenuation that brings the
/// louder preset down to the quieter one. We never amplify, to keep headroom.
///
/// "Pink" weighting is implicit: log-spaced sample points give equal weight per
/// octave, which is the same thing pink-weighted RMS gives over a flat grid.
enum LoudnessMatcher {
    /// Broadband loudness number for a preset, in dB. Combines the preset's own
    /// preamp with the log-pink-weighted RMS of its magnitude curve.
    static func broadbandGainDB(preset: EQPreset, sampleCount: Int = 256) -> Double {
        precondition(sampleCount >= 2)
        let fMin = EQCurveGeometry.minFreq
        let fMax = EQCurveGeometry.maxFreq
        var meanSq = 0.0
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleCount - 1)
            let f = fMin * pow(fMax / fMin, t)
            // Pass preamp 0 so we add it once at the end as a single dB offset
            // rather than counting it inside every sample.
            let dB = EQCurveGeometry.totalDB(at: f, bands: preset.bands, preamp: 0)
            meanSq += pow(10.0, dB / 10.0)
        }
        meanSq /= Double(sampleCount)
        return 10.0 * log10(meanSq) + Double(preset.preamp)
    }

    /// Per-slot attenuation in dB (always ≤ 0) so both presets reach the lower
    /// of the two broadband gains. One return value will be exactly 0.
    static func equalAttenuationsDB(presetA: EQPreset, presetB: EQPreset) -> (a: Float, b: Float) {
        let gA = broadbandGainDB(preset: presetA)
        let gB = broadbandGainDB(preset: presetB)
        let target = min(gA, gB)
        return (Float(target - gA), Float(target - gB))
    }
}
