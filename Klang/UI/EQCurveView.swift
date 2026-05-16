import SwiftUI

/// Renders the combined frequency response of a set of EQ bands using
/// `EQCurveGeometry`'s closed-form magnitude math.
/// Log frequency axis 20 Hz – 20 kHz; linear dB axis ±15 dB (visible ±12 dB gridlines).
struct EQCurveView: View {
    let bands: [EQBand]
    let preamp: Float

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

    private func drawCurve(ctx: inout GraphicsContext, size: CGSize) {
        var path = Path()
        var fill = Path()
        let yZero = EQCurveGeometry.yPos(forDB: 0, minDB: minDB, maxDB: maxDB, in: size)
        var started = false

        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let f = EQCurveGeometry.minFreq * pow(EQCurveGeometry.maxFreq / EQCurveGeometry.minFreq, t)
            let dB = EQCurveGeometry.totalDB(at: f, bands: bands, preamp: preamp)
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

        ctx.fill(fill, with: .color(Color.accentColor.opacity(0.18)))
        ctx.stroke(path, with: .color(Color.accentColor), lineWidth: 2)
    }
}
