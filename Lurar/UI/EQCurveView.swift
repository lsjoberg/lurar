import SwiftUI

/// Renders the combined frequency response of a set of EQ bands using
/// `EQCurveGeometry`'s closed-form magnitude math.
/// Log frequency axis 20 Hz – 20 kHz; linear dB axis ±15 dB (visible ±12 dB gridlines).
///
/// Conforms to `Equatable` so callers can wrap us in `.equatable()` and have
/// SwiftUI skip the canvas redraw when our inputs are unchanged — used by the
/// editor's slider-drag freeze to suppress the 128-sample biquad recompute
/// until the mouse comes back up.
struct EQCurveView: View, Equatable {
    let bands: [EQBand]
    let preamp: Float
    /// Optional parent-preset curve to draw as a dashed reference behind the
    /// live curve. Used by the editor to show "what you forked from" when the
    /// current preset has a `parentRef`.
    var referenceBands: [EQBand]? = nil
    var referencePreamp: Float? = nil

    static func == (lhs: EQCurveView, rhs: EQCurveView) -> Bool {
        lhs.bands == rhs.bands
            && lhs.preamp == rhs.preamp
            && lhs.referenceBands == rhs.referenceBands
            && lhs.referencePreamp == rhs.referencePreamp
    }

    private let minDB: Double = -15
    private let maxDB: Double = 15
    /// Display-only sample count. 128 is visually indistinguishable from 256
    /// at typical editor widths but halves the per-frame biquad work, which
    /// matters during slider drags where the curve re-renders on every value
    /// change.
    private let samples = 128

    var body: some View {
        Canvas { ctx, size in
            drawGrid(ctx: &ctx, size: size)
            // Compute response cache once per redraw and reuse for fill + stroke
            // so coefficients aren't rebuilt twice per band.
            let responses = bands.map { EQCurveGeometry.BandResponse(band: $0) }
            let refResponses = referenceBands?.map { EQCurveGeometry.BandResponse(band: $0) }
            drawCurveFill(ctx: &ctx, size: size, responses: responses)
            if let refResponses {
                drawReferenceCurve(ctx: &ctx, size: size,
                                   responses: refResponses,
                                   preamp: referencePreamp ?? 0)
            }
            drawCurveStroke(ctx: &ctx, size: size, responses: responses)
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

        let yZero = EQCurveGeometry.yPos(forDB: 0, minDB: minDB, maxDB: maxDB, in: size)
        var midPath = Path()
        midPath.move(to: CGPoint(x: 0, y: yZero))
        midPath.addLine(to: CGPoint(x: size.width, y: yZero))
        ctx.stroke(midPath, with: .color(.secondary.opacity(0.4)), lineWidth: 1)

        for db in stride(from: -12.0, through: 12.0, by: 3.0) where db != 0 {
            let y = EQCurveGeometry.yPos(forDB: db, minDB: minDB, maxDB: maxDB, in: size)
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

        let decadeFreqs: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]
        for f in decadeFreqs {
            let x = EQCurveGeometry.xPos(forFreq: f, in: size)
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

    private func drawCurveFill(ctx: inout GraphicsContext, size: CGSize, responses: [EQCurveGeometry.BandResponse]) {
        let (_, fill) = curvePaths(in: size, responses: responses, preamp: preamp)
        ctx.fill(fill, with: .color(Color.accentColor.opacity(0.18)))
    }

    private func drawCurveStroke(ctx: inout GraphicsContext, size: CGSize, responses: [EQCurveGeometry.BandResponse]) {
        let (path, _) = curvePaths(in: size, responses: responses, preamp: preamp)
        ctx.stroke(path, with: .color(Color.accentColor), lineWidth: 2)
    }

    /// Build both the stroke and filled paths for a given band set. Two passes
    /// (fill, then stroke) let us insert the dashed reference between them.
    private func curvePaths(in size: CGSize, responses: [EQCurveGeometry.BandResponse], preamp: Float) -> (Path, Path) {
        var path = Path()
        var fill = Path()
        let yZero = EQCurveGeometry.yPos(forDB: 0, minDB: minDB, maxDB: maxDB, in: size)
        var started = false

        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let f = EQCurveGeometry.minFreq * pow(EQCurveGeometry.maxFreq / EQCurveGeometry.minFreq, t)
            var dB = Double(preamp)
            for r in responses { dB += r.magnitudeDB(at: f) }
            let x = EQCurveGeometry.xPos(forFreq: f, in: size)
            let y = EQCurveGeometry.yPos(forDB: dB, minDB: minDB, maxDB: maxDB, in: size)
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
        return (path, fill)
    }

    /// Dashed line, no fill — drawn between the live fill and the live stroke
    /// so the active response stays the most prominent element while the
    /// parent reference remains visible everywhere the curves overlap.
    private func drawReferenceCurve(ctx: inout GraphicsContext, size: CGSize, responses: [EQCurveGeometry.BandResponse], preamp: Float) {
        let (path, _) = curvePaths(in: size, responses: responses, preamp: preamp)
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4])
        ctx.stroke(path, with: .color(.secondary.opacity(0.65)), style: style)
    }
}
