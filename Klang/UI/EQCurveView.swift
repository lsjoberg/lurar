import SwiftUI

/// Renders the combined frequency response of a set of EQ bands using closed-form
/// magnitude expressions for the equivalent analog filters (RBJ-style).
/// Log frequency axis 20 Hz – 20 kHz; linear dB axis ±12 dB (plus preamp).
struct EQCurveView: View {
    let bands: [EQBand]
    let preamp: Float

    private let minFreq: Double = 20
    private let maxFreq: Double = 20_000
    private let minDB: Double = -15
    private let maxDB: Double = 15
    private let samples = 256

    var body: some View {
        Canvas { ctx, size in
            drawGrid(ctx: &ctx, size: size)
            drawCurve(ctx: &ctx, size: size)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    // MARK: - Drawing

    private func drawGrid(ctx: inout GraphicsContext, size: CGSize) {
        let gridColor = Color.secondary.opacity(0.18)
        let labelColor = Color.secondary

        // Zero-dB midline
        let yZero = yPos(forDB: 0, in: size)
        var midPath = Path()
        midPath.move(to: CGPoint(x: 0, y: yZero))
        midPath.addLine(to: CGPoint(x: size.width, y: yZero))
        ctx.stroke(midPath, with: .color(.secondary.opacity(0.4)), lineWidth: 1)

        // dB lines at ±3, ±6, ±9, ±12
        for db in stride(from: -12.0, through: 12.0, by: 3.0) where db != 0 {
            let y = yPos(forDB: db, in: size)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 1)
            ctx.draw(
                Text("\(Int(db))").font(.system(size: 9)).foregroundColor(labelColor),
                at: CGPoint(x: size.width - 12, y: y - 6),
                anchor: .topTrailing
            )
        }

        // Decade frequency lines.
        let decadeFreqs: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]
        for f in decadeFreqs {
            let x = xPos(forFreq: f, in: size)
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 1)
            let label = f >= 1000 ? "\(Int(f/1000))k" : "\(Int(f))"
            ctx.draw(
                Text(label).font(.system(size: 9)).foregroundColor(labelColor),
                at: CGPoint(x: x + 2, y: size.height - 12),
                anchor: .topLeading
            )
        }
    }

    private func drawCurve(ctx: inout GraphicsContext, size: CGSize) {
        var path = Path()
        var fill = Path()
        let yZero = yPos(forDB: 0, in: size)
        var started = false

        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let f = minFreq * pow(maxFreq / minFreq, t)
            let dB = totalDB(at: f)
            let x = xPos(forFreq: f, in: size)
            let y = yPos(forDB: dB, in: size)
            if !started {
                path.move(to: CGPoint(x: x, y: y))
                fill.move(to: CGPoint(x: x, y: yZero))
                fill.addLine(to: CGPoint(x: x, y: y))
                started = true
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
                fill.addLine(to: CGPoint(x: x, y: y))
            }
            if i == samples {
                fill.addLine(to: CGPoint(x: x, y: yZero))
                fill.closeSubpath()
            }
        }

        ctx.fill(fill, with: .color(Color.accentColor.opacity(0.18)))
        ctx.stroke(path, with: .color(Color.accentColor), lineWidth: 2)
    }

    // MARK: - Math

    /// Sum of all band magnitude responses (dB) plus preamp.
    private func totalDB(at frequency: Double) -> Double {
        var total = Double(preamp)
        for band in bands {
            total += bandDB(at: frequency, band: band)
        }
        return total
    }

    /// RBJ Audio EQ Cookbook magnitude response for a single biquad. Uses a reference sample rate
    /// for the bilinear transform; the curve is reasonably accurate well below Nyquist, which is
    /// what matters for a 20 Hz – 20 kHz display.
    private func bandDB(at frequency: Double, band: EQBand) -> Double {
        let fs = 96_000.0
        let f0 = Double(band.frequency)
        let gainDB = Double(band.gain)
        let Q = max(Double(band.q), 0.001)
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2 * Double.pi * f0 / fs
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2 * Q)

        let b0, b1, b2, a0, a1, a2: Double

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

        // Evaluate |H(e^{jw})| at the probe frequency.
        let w = 2 * Double.pi * frequency / fs
        let cosw = cos(w)
        let cos2w = cos(2 * w)
        let sinw = sin(w)
        let sin2w = sin(2 * w)

        // Numerator/denominator real & imaginary parts: b0 + b1 e^{-jw} + b2 e^{-j2w}
        let numRe = b0 + b1 * cosw + b2 * cos2w
        let numIm = -(b1 * sinw + b2 * sin2w)
        let denRe = a0 + a1 * cosw + a2 * cos2w
        let denIm = -(a1 * sinw + a2 * sin2w)

        let numMag = sqrt(numRe * numRe + numIm * numIm)
        let denMag = sqrt(denRe * denRe + denIm * denIm)
        guard denMag > 0 else { return 0 }
        return 20 * log10(numMag / denMag)
    }

    // MARK: - Coordinate mapping

    private func xPos(forFreq f: Double, in size: CGSize) -> CGFloat {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let t = (log10(f) - logMin) / (logMax - logMin)
        return CGFloat(t) * size.width
    }

    private func yPos(forDB db: Double, in size: CGSize) -> CGFloat {
        let clamped = min(max(db, minDB), maxDB)
        let t = (maxDB - clamped) / (maxDB - minDB)
        return CGFloat(t) * size.height
    }
}
