import SwiftUI

/// Two-channel peak meter for the post-EQ output, with a sticky clip
/// indicator. Sits under the preamp slider so the user can see how close a
/// boosted preset is pushing the output to 0 dBFS — and whether it has
/// actually clipped in the last 2 s.
///
/// Driven by `TimelineView(.periodic)` like `SpectrumOverlayView` so the 30 Hz
/// redraw doesn't invalidate the surrounding editor view tree. The meter
/// reads directly from the analyzer in the Canvas closure — no Combine
/// publisher, no `Timer`, no per-frame `@Published` invalidation.
///
/// Click anywhere on the meter (bars or the sticky dot) to clear the clip
/// latch. The latch will re-arm immediately if real clipping is still
/// happening on the next audio callback.
struct ClipMeterView: View {
    let clipMeter: ClipMeter

    /// dBFS range the bar visualises. The bottom of the scale matches the
    /// noise floor of typical music; the top is hard clip.
    private let minDB: Double = -60
    private let maxDB: Double = 0
    /// Where the bar transitions from "safe" to "headroom warning" colour.
    private let redZoneDB: Double = -3
    /// 30 Hz wall-clock cadence, matching `SpectrumOverlayView`.
    private let interval: TimeInterval = 1.0 / 30.0

    private let barHeight: CGFloat = 5
    private let barSpacing: CGFloat = 2
    private let labelWidth: CGFloat = 14
    private let dotSize: CGFloat = 10
    private let dotGap: CGFloat = 8

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { timeline in
            // Capture timeline.date inside the renderer so SwiftUI re-invokes
            // the Canvas closure each tick — same trick as SpectrumOverlayView.
            let date = timeline.date
            Canvas { ctx, size in
                _ = date
                let snap = clipMeter.snapshot()
                draw(ctx: &ctx, size: size, snap: snap)
            }
            .frame(height: barHeight * 2 + barSpacing)
            .contentShape(Rectangle())
            .onTapGesture { clipMeter.clearClip() }
            .help("Post-EQ output peak (L/R). The dot lights when any sample clipped in the last 2 s — click to clear.")
        }
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize, snap: ClipMeter.Snapshot) {
        let meterX = labelWidth
        let meterWidth = max(0, size.width - labelWidth - dotGap - dotSize)
        let lRect = CGRect(x: meterX, y: 0, width: meterWidth, height: barHeight)
        let rRect = CGRect(x: meterX, y: barHeight + barSpacing, width: meterWidth, height: barHeight)

        drawChannelLabel(ctx: &ctx, text: "L", rect: CGRect(x: 0, y: lRect.minY, width: labelWidth, height: barHeight))
        drawChannelLabel(ctx: &ctx, text: "R", rect: CGRect(x: 0, y: rRect.minY, width: labelWidth, height: barHeight))

        drawBar(ctx: &ctx, peakDB: Double(snap.peakDBL), rect: lRect)
        drawBar(ctx: &ctx, peakDB: Double(snap.peakDBR), rect: rRect)

        // Sticky-clip dot, vertically centred over the two bars.
        let dotY = (barHeight * 2 + barSpacing - dotSize) / 2
        let dotRect = CGRect(x: size.width - dotSize, y: dotY, width: dotSize, height: dotSize)
        let dotPath = Path(ellipseIn: dotRect)
        if snap.clipped {
            ctx.fill(dotPath, with: .color(.red))
            ctx.stroke(dotPath, with: .color(.red.opacity(0.5)), lineWidth: 1)
        } else {
            ctx.fill(dotPath, with: .color(.red.opacity(0.12)))
            ctx.stroke(dotPath, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
        }
    }

    private func drawChannelLabel(ctx: inout GraphicsContext, text: String, rect: CGRect) {
        let resolved = ctx.resolve(Text(text).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary))
        let textSize = resolved.measure(in: CGSize(width: rect.width, height: rect.height))
        let origin = CGPoint(x: rect.minX, y: rect.midY - textSize.height / 2)
        ctx.draw(resolved, at: origin, anchor: .topLeading)
    }

    private func drawBar(ctx: inout GraphicsContext, peakDB: Double, rect: CGRect) {
        let corner = CGSize(width: rect.height / 2, height: rect.height / 2)

        // Track.
        let track = Path(roundedRect: rect, cornerSize: corner)
        ctx.fill(track, with: .color(.secondary.opacity(0.18)))

        // Convert peak to a fill width within `rect`.
        let clamped = max(minDB, min(maxDB, peakDB))
        let t = (clamped - minDB) / (maxDB - minDB)
        let fillWidth = rect.width * CGFloat(t)
        guard fillWidth > 0 else { return }

        let redT = (redZoneDB - minDB) / (maxDB - minDB)
        let redStartX = rect.width * CGFloat(redT)

        // Clip the fill to the rounded-rect track so the bar visually inherits
        // the track's pill shape regardless of the safe/danger split.
        ctx.drawLayer { layer in
            layer.clip(to: track)
            if fillWidth <= redStartX {
                let r = CGRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
                layer.fill(Path(r), with: .color(.green.opacity(0.85)))
            } else {
                let safe = CGRect(x: rect.minX, y: rect.minY, width: redStartX, height: rect.height)
                let danger = CGRect(x: rect.minX + redStartX, y: rect.minY,
                                    width: fillWidth - redStartX, height: rect.height)
                layer.fill(Path(safe), with: .color(.green.opacity(0.85)))
                layer.fill(Path(danger), with: .color(.red.opacity(0.95)))
            }
        }
    }
}
