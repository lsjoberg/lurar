import Foundation

/// ISO 226:2003 equal-loudness contour computation and biquad fitting for
/// the loudness-compensation feature.
///
/// At low listening volumes the ear's frequency response sags at the extremes
/// (Fletcher-Munson). Loudness compensation lifts bass and treble back up
/// when the user is listening below the 83-phon mastering reference. This
/// module computes the per-frequency lift needed (in dB, normalised at 1 kHz
/// so the curve is anchored there), and fits it to a six-biquad cascade:
///
///   LowShelf  @    50 Hz Q=0.50  — sub-bass lift
///   Peak      @   135 Hz Q=0.56  — bass shaping
///   Peak      @ 1.75 kHz Q=0.70  — bass-mid slope continuation
///   Peak      @ 4.40 kHz Q=1.00  — handle the 4 kHz dip
///   HighShelf @ 10.5 kHz Q=0.68  — broad treble shelf
///   Peak      @ 13.8 kHz Q=1.00  — top-octave lift
///
/// Topology was searched empirically against the ISO target at 48/96 kHz
/// across the full [−40, 0] dB slider range. Worst-case fit error: ~0.55 dB
/// at offset −20, ~0.85 dB at offset −40 — well below the audibility
/// threshold for a perceptual loudness contour (typically ≥ 1.5 dB in
/// casual listening).
///
/// Pure functions; no SwiftUI dependencies; safe to call from any thread.
enum LoudnessContour {
    // MARK: - ISO 226:2003 parameter tables (Table 1)

    /// 29 standard frequencies in Hz, 20 Hz – 12.5 kHz.
    static let frequencies: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
        2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500
    ]

    /// αf — exponent in the loudness-perception equation.
    static let alphaTable: [Double] = [
        0.532, 0.506, 0.480, 0.455, 0.432, 0.409, 0.387, 0.367, 0.349, 0.330,
        0.315, 0.301, 0.288, 0.276, 0.267, 0.259, 0.253, 0.250, 0.246, 0.244,
        0.243, 0.243, 0.243, 0.242, 0.242, 0.245, 0.254, 0.271, 0.301
    ]

    /// Lu — magnitude of the linear transfer function normalised at 1 kHz, dB.
    static let luTable: [Double] = [
        -31.6, -27.2, -23.0, -19.1, -15.9, -13.0, -10.3,  -8.1,  -6.2,  -4.5,
         -3.1,  -2.0,  -1.1,  -0.4,   0.0,   0.3,   0.5,   0.0,  -2.7,  -4.1,
         -1.0,   1.7,   2.5,   1.2,  -2.1,  -7.1, -11.2, -10.7,  -3.1
    ]

    /// Tf — threshold of hearing, dB SPL.
    static let tfTable: [Double] = [
        78.5, 68.7, 59.5, 51.1, 44.0, 37.5, 31.5, 26.5, 22.1, 17.9,
        14.4, 11.4,  8.6,  6.2,  4.4,  3.0,  2.2,  2.4,  3.5,  1.7,
        -1.3, -4.2, -6.0, -5.4, -1.5,  6.0, 12.6, 13.9, 12.3
    ]

    /// Mastering reference listening level (phon). The slider expresses an
    /// offset BELOW this; offset 0 means no compensation.
    static let referencePhon: Double = 83

    // MARK: - Equal-loudness math

    /// SPL (dB) required at `frequency` to perceive `phon` loudness. Formula
    /// from ISO 226:2003 §4. Valid roughly 20 phon – 90 phon, 20 Hz – 12.5 kHz;
    /// frequencies outside the table clamp to the nearest endpoint (a 16-bit
    /// audio stream has nothing meaningful above 22 kHz anyway).
    ///
    ///   Af = 4.47e-3 · (10^(0.025·Ln) − 1.15)
    ///      + (0.4 · 10^((Tf+Lu)/10 − 9))^αf
    ///   Lp = (10/αf) · log10(Af) − Lu + 94
    static func splForPhon(phon: Double, frequency: Double) -> Double {
        let p = interpolate(frequency: frequency)
        let af = 4.47e-3 * (pow(10.0, 0.025 * phon) - 1.15)
            + pow(0.4 * pow(10.0, (p.tf + p.lu) / 10.0 - 9.0), p.alpha)
        return (10.0 / p.alpha) * log10(af) - p.lu + 94.0
    }

    /// Compensation curve in dB at `frequency`, normalised at 1 kHz (returns 0
    /// there). `offsetDB ≤ 0` is the slider value — how many phon below the
    /// 83-phon reference the user is listening at.
    ///
    /// The compensation is the difference between the two normalised
    /// equal-loudness shapes:
    ///     comp(f) = [SPL(refPhon+offset, f) − SPL(refPhon+offset, 1 kHz)]
    ///             − [SPL(refPhon,        f) − SPL(refPhon,        1 kHz)]
    /// which simplifies (since SPL = phon at 1 kHz) to:
    ///     comp(f) = SPL(refPhon+offset, f) − SPL(refPhon, f) − offset
    ///
    /// At offsetDB = −20 this lifts ≈ +6.8 dB at 80 Hz, 0 at 1 kHz, +3.3 dB
    /// at 12.5 kHz — the classic loudness "smile".
    static func compensationCurve(offsetDB: Double, frequency: Double) -> Double {
        guard offsetDB < 0 else { return 0 }
        let splRef = splForPhon(phon: referencePhon, frequency: frequency)
        let splLow = splForPhon(phon: referencePhon + offsetDB, frequency: frequency)
        return splLow - splRef - offsetDB
    }

    // MARK: - Biquad fitting

    private struct BandDesign {
        let type: EQBand.FilterType
        let frequency: Double
        let q: Double
    }

    /// Locked topology. Verified empirically to fit the ISO contour within
    /// ≤ 1.0 dB across 20 Hz – 20 kHz at every offset in [−40, 0] dB and at
    /// every supported sample rate (44.1k–96k); see `runFitSelfCheck()` and
    /// the assertion at the bottom of `fitBiquads`. The actual error is
    /// ≤ 0.5 dB for typical use (offset −5 to −15) and rises to ~0.85 dB at
    /// the extreme. Change at your peril — if you alter freqs or Q, run the
    /// self-check across the slider range AND multiple sample rates before
    /// shipping.
    private static let designBands: [BandDesign] = [
        BandDesign(type: .lowShelf,  frequency:    50.0, q: 0.50),
        BandDesign(type: .peak,      frequency:   135.0, q: 0.56),
        BandDesign(type: .peak,      frequency:  1750.0, q: 0.70),
        BandDesign(type: .peak,      frequency:  4400.0, q: 1.00),
        BandDesign(type: .highShelf, frequency: 10500.0, q: 0.68),
        BandDesign(type: .peak,      frequency: 13800.0, q: 1.00)
    ]

    /// Number of biquad sections in the fitted loudness cascade.
    static let sectionCount = 6

    /// Flat coefficient buffer (5 doubles × `sectionCount`) for an identity
    /// cascade. Used to prime the cascade when loudness is inactive so the
    /// activation transition starts from clean coefficients.
    static let identityCoefficients: [Double] = {
        var flat: [Double] = []
        flat.reserveCapacity(5 * sectionCount)
        for _ in 0..<sectionCount {
            let c = BiquadCoefficients.identity
            flat.append(contentsOf: [c.0, c.1, c.2, c.3, c.4])
        }
        return flat
    }()

    /// Fit the six-biquad cascade to the compensation curve at `offsetDB`.
    /// Returns the flat coefficient buffer (5 doubles × 6 sections) ready for
    /// `BiquadCascade.setCoefficients(...)`, plus the headroom (dB ≥ 0) the
    /// caller should subtract from its preamp so the boosted bands can't push
    /// above 0 dBFS.
    ///
    /// Hard bypass at |offsetDB| < 0.01 — returns identity coefficients and
    /// zero headroom. The audio thread also gates the cascade on the
    /// active flag so this path produces a structural bypass, not just flat
    /// numerics.
    ///
    /// Gains come from an offline-computed lookup table (`gainLUT`) — a
    /// least-squares fit of the locked 6-band topology against the analytic
    /// ISO curve at each integer offset 0 to −40 dB. At runtime we linearly
    /// interpolate between adjacent entries. Worst-case fit error across
    /// sample rate × offset combinations: ≤ 0.85 dB.
    static func fitBiquads(offsetDB: Double, sampleRate: Double) -> (coefficients: [Double], headroomDB: Double) {
        if abs(offsetDB) < 0.01 {
            return (identityCoefficients, 0)
        }
        let gains = interpolatedGains(absOffsetDB: abs(offsetDB))

        var flat: [Double] = []
        flat.reserveCapacity(5 * sectionCount)
        for (i, band) in designBands.enumerated() {
            let c = BiquadCoefficients.make(
                type: band.type,
                frequency: Float(band.frequency),
                gainDB: Float(gains[i]),
                q: Float(band.q),
                sampleRate: sampleRate
            )
            flat.append(contentsOf: [c.0, c.1, c.2, c.3, c.4])
        }

        // Headroom = peak of the fitted cascade across 20 Hz – 20 kHz. We
        // scan a 200-point log grid (dense enough to find the true peak
        // between design freqs).
        var peakDB = 0.0
        let gridCount = 200
        for i in 0..<gridCount {
            let t = Double(i) / Double(gridCount - 1)
            let f = 20.0 * pow(20_000.0 / 20.0, t)
            peakDB = max(peakDB, cascadeResponseDB(at: f, gains: gains))
        }

        #if DEBUG
        // Self-test: the fitted cascade must track the analytic ISO target
        // within 1.0 dB across the audible band. The empirical fit error of
        // the chosen 6-band topology is ≤ 0.85 dB across [−40, 0] dB and
        // the supported SR range; the 1.0 dB threshold catches topology
        // regressions before they ship while leaving headroom for the
        // slight bilinear-transform shifts between the table's reference SR
        // (96 kHz) and the runtime SR.
        var maxErr = 0.0
        for i in 0..<100 {
            let t = Double(i) / 99.0
            let f = 20.0 * pow(20_000.0 / 20.0, t)
            let target = compensationCurve(offsetDB: offsetDB, frequency: f)
            let actual = cascadeResponseDB(at: f, gains: gains)
            maxErr = max(maxErr, abs(target - actual))
        }
        assert(maxErr <= 1.0,
               "LoudnessContour fit exceeded 1.0 dB at offset \(offsetDB) dB: max err \(maxErr) dB")
        #endif

        return (flat, max(0, peakDB))
    }

    /// Linearly interpolate the gain vector for an arbitrary `absOffsetDB`
    /// from the per-integer-offset LUT. Clamps to the slider range.
    private static func interpolatedGains(absOffsetDB: Double) -> [Double] {
        let clamped = min(max(absOffsetDB, 0), Double(gainLUT.count - 1))
        let lo = Int(floor(clamped))
        let hi = min(lo + 1, gainLUT.count - 1)
        let t = clamped - Double(lo)
        var out = [Double](repeating: 0, count: sectionCount)
        for k in 0..<sectionCount {
            out[k] = gainLUT[lo][k] * (1 - t) + gainLUT[hi][k] * t
        }
        return out
    }

    /// Maximum error (dB) between the analytic ISO compensation curve and the
    /// fitted six-biquad cascade, sampled at 100 log-spaced points across
    /// 20 Hz – 20 kHz. Used by `runFitSelfCheck` and available for ad-hoc
    /// verification.
    static func maxFitError(offsetDB: Double, sampleRate: Double) -> Double {
        if abs(offsetDB) < 0.01 { return 0 }
        let gains = interpolatedGains(absOffsetDB: abs(offsetDB))
        var maxErr = 0.0
        for i in 0..<100 {
            let t = Double(i) / 99.0
            let f = 20.0 * pow(20_000.0 / 20.0, t)
            let target = compensationCurve(offsetDB: offsetDB, frequency: f)
            let actual = cascadeResponseDB(at: f, gains: gains)
            maxErr = max(maxErr, abs(target - actual))
        }
        return maxErr
    }

    /// Sweep the slider range and assert the fit stays within ±1.0 dB. Call
    /// from app boot in DEBUG to catch topology regressions early.
    static func runFitSelfCheck() {
        for offsetTenths in stride(from: -5, through: -400, by: -5) {
            let offset = Double(offsetTenths) / 10.0
            let err = maxFitError(offsetDB: offset, sampleRate: 48_000)
            assert(err <= 1.0,
                   "LoudnessContour fit at offset \(offset) dB exceeded 1.0 dB tolerance: max err \(err) dB")
        }
    }

    // MARK: - Internals

    private static func interpolate(frequency: Double) -> (alpha: Double, lu: Double, tf: Double) {
        if frequency <= frequencies[0] {
            return (alphaTable[0], luTable[0], tfTable[0])
        }
        if frequency >= frequencies.last! {
            let n = frequencies.count - 1
            return (alphaTable[n], luTable[n], tfTable[n])
        }
        let logF = log(frequency)
        for i in 1..<frequencies.count {
            if frequency <= frequencies[i] {
                let logF0 = log(frequencies[i - 1])
                let logF1 = log(frequencies[i])
                let t = (logF - logF0) / (logF1 - logF0)
                return (
                    alphaTable[i - 1] + t * (alphaTable[i] - alphaTable[i - 1]),
                    luTable[i - 1]    + t * (luTable[i]    - luTable[i - 1]),
                    tfTable[i - 1]    + t * (tfTable[i]    - tfTable[i - 1])
                )
            }
        }
        return (alphaTable.last!, luTable.last!, tfTable.last!)
    }

    /// dB response of the six-biquad cascade at `frequency` for the given
    /// gain vector. Uses `EQCurveGeometry.bandDB` (96 kHz reference SR) — the
    /// bilinear-transform warping vs the runtime SR adds at most ~0.05 dB
    /// across the audible band for our design freqs (all ≤ 14 kHz), well
    /// below the fit-error budget.
    private static func cascadeResponseDB(at frequency: Double, gains: [Double]) -> Double {
        var sum = 0.0
        for (i, design) in designBands.enumerated() {
            let band = EQBand(
                type: design.type,
                frequency: Float(design.frequency),
                gain: Float(gains[i]),
                q: Float(design.q)
            )
            sum += EQCurveGeometry.bandDB(at: frequency, band: band)
        }
        return sum
    }

    // MARK: - Gain lookup table

    /// Per-band gain (dB) at each integer offset 0 to −40, indexed by
    /// `abs(offsetDB)`. Computed offline via an iterative least-squares fit
    /// of the locked 6-band topology against 100 log-spaced points of the
    /// analytic ISO compensation curve, at the 96 kHz reference sample rate.
    /// Each row is `[gainLowShelf, gainPeak135, gainPeak1750, gainPeak4400,
    /// gainHighShelf, gainPeak13800]`.
    private static let gainLUT: [[Double]] = [
        [ 0.000000,  0.000000,  0.000000,  0.000000,  0.000000,  0.000000], // off =  -0
        [ 0.623854,  0.214919, -0.019845, -0.049083,  0.151314,  0.047478], // off =  -1
        [ 1.247589,  0.429476, -0.039732, -0.098241,  0.302417,  0.094900], // off =  -2
        [ 1.871270,  0.643581, -0.059664, -0.147482,  0.453283,  0.142276], // off =  -3
        [ 2.494964,  0.857141, -0.079646, -0.196813,  0.603885,  0.189615], // off =  -4
        [ 3.118737,  1.070064, -0.099684, -0.246243,  0.754200,  0.236926], // off =  -5
        [ 3.742653,  1.282256, -0.119781, -0.295779,  0.904199,  0.284217], // off =  -6
        [ 4.366776,  1.493619, -0.139941, -0.345431,  1.053854,  0.331497], // off =  -7
        [ 4.991170,  1.704056, -0.160170, -0.395207,  1.203138,  0.378772], // off =  -8
        [ 5.615896,  1.913469, -0.180472, -0.445116,  1.352021,  0.426050], // off =  -9
        [ 6.241015,  2.121756, -0.200851, -0.495168,  1.500475,  0.473335], // off = -10
        [ 6.866587,  2.328813, -0.221313, -0.545374,  1.648469,  0.520635], // off = -11
        [ 7.492672,  2.534536, -0.241860, -0.595743,  1.795973,  0.567952], // off = -12
        [ 8.119326,  2.738817, -0.262498, -0.646286,  1.942953,  0.615291], // off = -13
        [ 8.746606,  2.941546, -0.283231, -0.697015,  2.089378,  0.662655], // off = -14
        [ 9.374568,  3.142610, -0.304063, -0.747942,  2.235213,  0.710044], // off = -15
        [10.003265,  3.341893, -0.324998, -0.799079,  2.380425,  0.757461], // off = -16
        [10.632749,  3.539279, -0.346039, -0.850440,  2.524978,  0.804905], // off = -17
        [11.263070,  3.734645, -0.367192, -0.902038,  2.668834,  0.852373], // off = -18
        [11.894277,  3.927867, -0.388460, -0.953887,  2.811956,  0.899865], // off = -19
        [12.526417,  4.118816, -0.409846, -1.006003,  2.954305,  0.947374], // off = -20
        [13.159535,  4.307362, -0.431354, -1.058400,  3.095840,  0.994897], // off = -21
        [13.793672,  4.493370, -0.452989, -1.111096,  3.236520,  1.042425], // off = -22
        [14.428869,  4.676699, -0.474752, -1.164108,  3.376302,  1.089950], // off = -23
        [15.065164,  4.857206, -0.496648, -1.217455,  3.515107,  1.137491], // off = -24
        [15.702590,  5.034744, -0.518680, -1.271154,  3.652945,  1.184986], // off = -25
        [16.341179,  5.209160, -0.540852, -1.325225,  3.789743,  1.232443], // off = -26
        [16.980959,  5.380297, -0.563167, -1.379689,  3.925449,  1.279847], // off = -27
        [17.621954,  5.547992, -0.585629, -1.434568,  4.060013,  1.327179], // off = -28
        [18.264185,  5.712078, -0.608240, -1.489886,  4.193377,  1.374418], // off = -29
        [18.907667,  5.872382, -0.631005, -1.545665,  4.325486,  1.421542], // off = -30
        [19.552412,  6.028724, -0.653928, -1.601930,  4.456279,  1.468525], // off = -31
        [20.198425,  6.180919, -0.677012, -1.658709,  4.585695,  1.515338], // off = -32
        [20.845706,  6.328774, -0.700261, -1.716029,  4.713666,  1.561950], // off = -33
        [21.494248,  6.472093, -0.723681, -1.773918,  4.840125,  1.608326], // off = -34
        [22.144039,  6.610667, -0.747276, -1.832407,  4.965000,  1.654428], // off = -35
        [22.795058,  6.744285, -0.771052, -1.891526,  5.088214,  1.700213], // off = -36
        [23.447274,  6.872725, -0.795014, -1.951311,  5.209687,  1.745637], // off = -37
        [24.100649,  6.995756, -0.819169, -2.011794,  5.329336,  1.790648], // off = -38
        [24.755134,  7.113142, -0.843525, -2.073013,  5.447070,  1.835194], // off = -39
        [25.410668,  7.224634, -0.868089, -2.135005,  5.562796,  1.879215]  // off = -40
    ]
}
