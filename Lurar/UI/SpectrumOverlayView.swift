import SwiftUI

/// Live FFT magnitude overlay, driven by `TimelineView(.periodic)` so it redraws on
/// a fixed wall-clock cadence without invalidating any surrounding views.
///
/// Past iterations of this overlay used a published `[Float]` magnitudes array on
/// an `ObservableObject` polled by a `Timer`. Every publish invalidated the entire
/// editor view (10 band editors, expensive EQ-curve trig math, etc.) at 30 Hz,
/// which felt laggy on slower hardware. `TimelineView` is opaque to the parent —
/// only its own closure re-renders. The analyzer's `snapshot()` is now called
/// directly inside the redraw, with no Combine layer in between.
///
/// Schedule note: we use `.periodic` rather than `.animation` because the latter
/// piggy-backs on the display link, which on macOS interacts poorly with closing
/// and re-opening the editor window — the timeline can keep the view "live" in a
/// way that prevents clean teardown. `.periodic` is just a wall-clock timer.
struct SpectrumOverlayView: View {
    let analyzer: SpectrumAnalyzer
    let isVisible: Bool

    /// dBFS range for the overlay. Pink-noise floor around -80 dB stays at the
    /// bottom; peaking sinusoid near 0 dB hits the top.
    private let spectrumMinDB: Double = -80
    private let spectrumMaxDB: Double = 0
    private let minFreq: Double = 20
    private let maxFreq: Double = 20_000
    /// Slightly coarser than the EQ curve (256 samples). Spectrum reads cleanly at
    /// 160 columns and saves a chunk of path-building work per frame.
    private let columns = 160
    /// Wall-clock cadence for the redraw. 30 Hz is plenty for a music visualizer.
    private let interval: TimeInterval = 1.0 / 30.0

    var body: some View {
        Group {
            if isVisible {
                TimelineView(.periodic(from: .now, by: interval)) { timeline in
                    // Capture `timeline.date` inside the Canvas renderer so SwiftUI sees the
                    // closure as "changed" each tick and re-invokes it. Without this, the
                    // Canvas's renderer captures only `analyzer` (a constant class reference),
                    // SwiftUI considers the output cacheable, and the overlay stays frozen on
                    // its first frame — i.e. invisible because the ring buffer is empty then.
                    let date = timeline.date
                    Canvas { ctx, size in
                        _ = date
                        let snap = analyzer.snapshot()
                        draw(ctx: &ctx, size: size,
                             magnitudes: snap.magnitudes, sampleRate: snap.sampleRate)
                    }
                }
            } else {
                Canvas { _, _ in }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize,
                      magnitudes: [Float], sampleRate: Double) {
        guard magnitudes.count > 1, sampleRate > 0 else { return }

        let binCount = magnitudes.count
        let nyquist = sampleRate / 2.0
        let binHz = nyquist / Double(binCount)
        // Half a 1/12-octave window on each side of the probe frequency.
        let octaveFraction = pow(2.0, 1.0 / 24.0)

        var path = Path()
        let bottom = size.height
        path.move(to: CGPoint(x: 0, y: bottom))

        magnitudes.withUnsafeBufferPointer { mag in
            for i in 0...columns {
                let t = Double(i) / Double(columns)
                let f = minFreq * pow(maxFreq / minFreq, t)
                let kLo = max(1, Int((f / octaveFraction / binHz).rounded(.down)))
                let kHi = min(binCount - 1, Int((f * octaveFraction / binHz).rounded(.up)))

                var peak: Float = -200
                if kLo <= kHi {
                    for k in kLo...kHi where mag[k] > peak {
                        peak = mag[k]
                    }
                }
                let db = min(max(Double(peak), spectrumMinDB), spectrumMaxDB)
                let yT = (spectrumMaxDB - db) / (spectrumMaxDB - spectrumMinDB)
                let x = xPos(forFreq: f, width: size.width)
                let y = CGFloat(yT) * size.height
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.addLine(to: CGPoint(x: size.width, y: bottom))
        path.closeSubpath()

        ctx.fill(path, with: .color(Color.secondary.opacity(0.28)))
    }

    private func xPos(forFreq f: Double, width: CGFloat) -> CGFloat {
        let logMin = log10(minFreq)
        let logMax = log10(maxFreq)
        let t = (log10(f) - logMin) / (logMax - logMin)
        return CGFloat(t) * width
    }
}
