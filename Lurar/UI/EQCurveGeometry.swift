import Foundation
import CoreGraphics

/// Closed-form magnitude math and coordinate mapping for EQ curve rendering.
/// Shared by the single-curve editor view and the two-curve A/B overlay so
/// both draw on the same axes and use the same reference filter response.
enum EQCurveGeometry {
    static let minFreq: Double = 20
    static let maxFreq: Double = 20_000

    /// Reference sample rate for the bilinear transform. Accurate well below
    /// Nyquist — fine for a 20 Hz – 20 kHz display, and signal-rate independent.
    static let referenceSampleRate: Double = 96_000

    /// Sum of all band magnitude responses (dB) plus preamp.
    /// Convenience wrapper that builds responses on every call — callers that
    /// evaluate many frequencies in a row should build `BandResponse`s once
    /// and call `magnitudeDB(at:)` directly to skip the per-frequency
    /// coefficient setup.
    static func totalDB(at frequency: Double, bands: [EQBand], preamp: Float) -> Double {
        var total = Double(preamp)
        for band in bands {
            total += BandResponse(band: band).magnitudeDB(at: frequency)
        }
        return total
    }

    /// RBJ Audio EQ Cookbook magnitude response for a single biquad.
    /// Single-frequency convenience for call sites that evaluate one point at
    /// a time. Curve rendering uses `BandResponse` directly for caching.
    static func bandDB(at frequency: Double, band: EQBand) -> Double {
        BandResponse(band: band).magnitudeDB(at: frequency)
    }

    /// Per-band biquad with its RBJ coefficients precomputed. Building this
    /// is the expensive part (one `pow`, four trig calls, plus the
    /// type-specific arithmetic); evaluating magnitude at a frequency is
    /// just four trig calls and a complex magnitude division. Build once per
    /// band and reuse across the curve's sample points.
    struct BandResponse {
        let b0, b1, b2, a0, a1, a2: Double

        init(band: EQBand) {
            let fs = EQCurveGeometry.referenceSampleRate
            let f0 = Double(band.frequency)
            let gainDB = Double(band.gain)
            let Q = max(Double(band.q), 0.001)
            let A = pow(10.0, gainDB / 40.0)
            let w0 = 2 * Double.pi * f0 / fs
            let cosw0 = cos(w0)
            let sinw0 = sin(w0)
            let alpha = sinw0 / (2 * Q)

            switch band.type {
            case .peak:
                b0 = 1 + alpha * A
                b1 = -2 * cosw0
                b2 = 1 - alpha * A
                a0 = 1 + alpha / A
                a1 = -2 * cosw0
                a2 = 1 - alpha / A
            case .lowShelf:
                let beta = 2 * sqrt(A) * alpha
                b0 = A * ((A + 1) - (A - 1) * cosw0 + beta)
                b1 = 2 * A * ((A - 1) - (A + 1) * cosw0)
                b2 = A * ((A + 1) - (A - 1) * cosw0 - beta)
                a0 = (A + 1) + (A - 1) * cosw0 + beta
                a1 = -2 * ((A - 1) + (A + 1) * cosw0)
                a2 = (A + 1) + (A - 1) * cosw0 - beta
            case .highShelf:
                let beta = 2 * sqrt(A) * alpha
                b0 = A * ((A + 1) + (A - 1) * cosw0 + beta)
                b1 = -2 * A * ((A - 1) + (A + 1) * cosw0)
                b2 = A * ((A + 1) + (A - 1) * cosw0 - beta)
                a0 = (A + 1) - (A - 1) * cosw0 + beta
                a1 = 2 * ((A - 1) - (A + 1) * cosw0)
                a2 = (A + 1) - (A - 1) * cosw0 - beta
            }
        }

        func magnitudeDB(at frequency: Double) -> Double {
            let w = 2 * Double.pi * frequency / EQCurveGeometry.referenceSampleRate
            let cosw = cos(w)
            let cos2w = cos(2 * w)
            let sinw = sin(w)
            let sin2w = sin(2 * w)

            let numRe = b0 + b1 * cosw + b2 * cos2w
            let numIm = -(b1 * sinw + b2 * sin2w)
            let denRe = a0 + a1 * cosw + a2 * cos2w
            let denIm = -(a1 * sinw + a2 * sin2w)

            let numMag = sqrt(numRe * numRe + numIm * numIm)
            let denMag = sqrt(denRe * denRe + denIm * denIm)
            guard denMag > 0 else { return 0 }
            return 20 * log10(numMag / denMag)
        }
    }

    // MARK: - Coordinate mapping

    static func xPos(forFreq f: Double, in size: CGSize) -> CGFloat {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let t = (log10(f) - logMin) / (logMax - logMin)
        return CGFloat(t) * size.width
    }

    static func yPos(forDB db: Double, minDB: Double, maxDB: Double, in size: CGSize) -> CGFloat {
        let clamped = min(max(db, minDB), maxDB)
        let t = (maxDB - clamped) / (maxDB - minDB)
        return CGFloat(t) * size.height
    }
}
