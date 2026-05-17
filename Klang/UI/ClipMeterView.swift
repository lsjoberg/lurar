import SwiftUI

/// Two-channel peak meter for the post-EQ output, with a sticky clip
/// indicator. Sits under the preamp slider so the user can see how close a
/// boosted preset is pushing the output to 0 dBFS — and whether it has
/// actually clipped in the last 2 s.
///
/// Driven by `TimelineView(.periodic)` like `SpectrumOverlayView` so the 30 Hz
/// redraw is opaque to the parent — the editor tree around it doesn't get
/// invalidated. The bar fills are rendered in a Canvas (cheap to redraw); the
/// `L`/`R` labels, header, and sticky dot are plain SwiftUI primitives so
/// typography stays sharp regardless of scale factor.
///
/// Click anywhere on the meter row (labels, bars, or sticky dot) to clear the
/// clip latch. It re-arms immediately if real clipping is still happening on
/// the next audio callback.
struct ClipMeterView: View {
    let clipMeter: ClipMeter
    @State private var showHelp: Bool = false

    /// dBFS range the bar visualises. The bottom of the scale matches the
    /// noise floor of typical music; the top is hard clip.
    private let minDB: Double = -60
    private let maxDB: Double = 0
    /// Where the bar transitions from "safe" to "headroom warning" colour.
    private let redZoneDB: Double = -3
    /// 30 Hz wall-clock cadence, matching `SpectrumOverlayView`.
    private let interval: TimeInterval = 1.0 / 30.0

    private let barHeight: CGFloat = 7
    private let barSpacing: CGFloat = 3
    private let labelColumnWidth: CGFloat = 12
    private let dotSize: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Output").bold()
                Button {
                    showHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("What does the output meter mean?")
                .popover(isPresented: $showHelp, arrowEdge: .top) {
                    helpContent
                }
                Spacer()
            }

            TimelineView(.periodic(from: .now, by: interval)) { timeline in
                // Touch timeline.date inside the closure so SwiftUI re-evaluates
                // each tick. Same idea as `SpectrumOverlayView`.
                _ = timeline.date
                let snap = clipMeter.snapshot()
                HStack(alignment: .center, spacing: 8) {
                    VStack(spacing: barSpacing) {
                        channelMeter(label: "L", peakDB: Double(snap.peakDBL))
                        channelMeter(label: "R", peakDB: Double(snap.peakDBR))
                    }
                    clipDot(active: snap.clipped)
                }
                .contentShape(Rectangle())
                .onTapGesture { clipMeter.clearClip() }
                .help("Click the meter to clear the sticky clip indicator.")
            }
        }
    }

    private func channelMeter(label: String, peakDB: Double) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: labelColumnWidth, alignment: .leading)
            Canvas { ctx, size in
                drawBar(ctx: &ctx, peakDB: peakDB,
                        rect: CGRect(origin: .zero, size: size))
            }
            .frame(height: barHeight)
        }
    }

    private func clipDot(active: Bool) -> some View {
        Circle()
            .fill(active ? Color.red : Color.red.opacity(0.12))
            .overlay(
                Circle().strokeBorder(
                    active ? Color.red.opacity(0.5) : Color.secondary.opacity(0.35),
                    lineWidth: active ? 1 : 0.5
                )
            )
            .frame(width: dotSize, height: dotSize)
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

    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Output peak").font(.headline)
            Text("Live peak level of the EQ + loudness output, left and right. The scale runs from \u{2212}60 dB up to 0 dB at the right edge \u{2014} the digital ceiling. Samples above 0 dB get flat-topped and start to sound harsh on transients.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The red dot latches whenever any sample hits the ceiling and stays lit for 2 s after the last clip, so brief clipping doesn\u{2019}t flash past unseen. Click the meter to clear it.")
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("How to read it").font(.subheadline.bold())
            VStack(alignment: .leading, spacing: 4) {
                helpRow("Green", "All clear \u{2014} output is well below the ceiling.")
                helpRow("Red tip", "Within 3 dB of clipping. Fine in short bursts, but pull Preamp down if loud passages are regularly running into the red.")
                helpRow("Red dot", "Clipped in the last 2 s. Lower Preamp a few dB \u{2014} or trim large positive band gains \u{2014} until the dot stops latching on loud parts of your music.")
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 340)
    }

    private func helpRow(_ label: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .bold()
                .frame(width: 64, alignment: .leading)
            Text(description)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
