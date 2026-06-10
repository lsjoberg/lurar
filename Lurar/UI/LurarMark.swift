import SwiftUI
import AppKit

/// Pure-SwiftUI Lurar brand mark. Composed of Shape primitives so it
/// scales without bundled assets. `face: false` drops eyes/mouth for
/// sub-pixel sizes (menu bar). `filled: false` hollows the earcups —
/// used to indicate engine-off state.
struct LurarMark: View {
    var face: Bool = true
    var filled: Bool = true
    var primary: Color = .accentColor
    var accent: Color = Self.coral

    static let coral = Color(red: 1.0, green: 0.478, blue: 0.349)

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let bandWeight = s * 0.065
            let faceWeight = s * 0.05

            ZStack {
                LurarHeadband()
                    .stroke(primary, style: StrokeStyle(lineWidth: bandWeight, lineCap: .round))

                if filled {
                    LurarCups().fill(primary)
                } else {
                    LurarCups().stroke(
                        primary,
                        style: StrokeStyle(lineWidth: bandWeight, lineCap: .round)
                    )
                }

                if face {
                    LurarEye().fill(accent)
                    LurarWink().stroke(
                        accent,
                        style: StrokeStyle(lineWidth: faceWeight, lineCap: .round)
                    )
                    LurarMouth().stroke(
                        accent,
                        style: StrokeStyle(lineWidth: faceWeight, lineCap: .round)
                    )
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct LurarHeadband: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0.16 * r.width, y: 0.52 * r.height))
            p.addQuadCurve(
                to: CGPoint(x: 0.84 * r.width, y: 0.52 * r.height),
                control: CGPoint(x: 0.50 * r.width, y: 0.10 * r.height)
            )
        }
    }
}

private struct LurarCups: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.addEllipse(in: CGRect(
                x: 0.03 * r.width,  y: 0.47 * r.height,
                width: 0.26 * r.width, height: 0.26 * r.height
            ))
            p.addEllipse(in: CGRect(
                x: 0.71 * r.width,  y: 0.47 * r.height,
                width: 0.26 * r.width, height: 0.26 * r.height
            ))
        }
    }
}

private struct LurarEye: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.addEllipse(in: CGRect(
                x: 0.35 * r.width,  y: 0.53 * r.height,
                width: 0.10 * r.width, height: 0.10 * r.height
            ))
        }
    }
}

private struct LurarWink: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0.54 * r.width, y: 0.60 * r.height))
            p.addQuadCurve(
                to: CGPoint(x: 0.66 * r.width, y: 0.60 * r.height),
                control: CGPoint(x: 0.60 * r.width, y: 0.52 * r.height)
            )
        }
    }
}

private struct LurarMouth: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0.43 * r.width, y: 0.75 * r.height))
            p.addQuadCurve(
                to: CGPoint(x: 0.57 * r.width, y: 0.70 * r.height),
                control: CGPoint(x: 0.50 * r.width, y: 0.77 * r.height)
            )
        }
    }
}

extension LurarMark {
    /// Rasterized template NSImage of the silhouette. Use for
    /// MenuBarExtra labels — SwiftUI doesn't reliably render custom
    /// Shape views as menu bar items; baked NSImages with isTemplate
    /// always do, and the system tints them for light/dark menu bars.
    @MainActor
    static func statusBarImage(filled: Bool, pointSize: CGFloat = 18) -> NSImage {
        let renderer = ImageRenderer(
            content: LurarMark(face: false, filled: filled, primary: .black)
                .frame(width: pointSize, height: pointSize)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.isTemplate = true
        return image
    }

    /// Brand mark with the output device's volume drawn beside it, baked into
    /// one template NSImage. Used when the "show volume in menu bar" setting is
    /// on (issue #118): the speaker sits *next to* the mark, so Lurar keeps its
    /// identity instead of being replaced by a generic volume icon.
    ///
    /// Baked into a single image for the same reason as `statusBarImage` —
    /// SwiftUI views render unreliably as menu bar labels. The speaker is a
    /// variable-value SF Symbol whose wave arcs fill in proportion to `volume`
    /// (0...1), matching the native macOS look. Callers pass a non-nil volume;
    /// for devices without a volume control they should fall back to
    /// `statusBarImage` (the plain mark).
    @MainActor
    static func statusBarImageWithVolume(
        filled: Bool,
        volume: Float,
        isMuted: Bool,
        pointSize: CGFloat = 18
    ) -> NSImage {
        let symbol = isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill"
        let glyph = Image(systemName: symbol, variableValue: isMuted ? nil : Double(volume))
            .font(.system(size: pointSize * 0.72))
            .foregroundStyle(.black)
        let renderer = ImageRenderer(
            content: HStack(spacing: pointSize * 0.2) {
                LurarMark(face: false, filled: filled, primary: .black)
                    .frame(width: pointSize, height: pointSize)
                glyph
            }
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let image = renderer.nsImage ?? statusBarImage(filled: filled, pointSize: pointSize)
        image.isTemplate = true
        return image
    }
}

#Preview {
    HStack(spacing: 24) {
        LurarMark().frame(width: 96, height: 96)
        LurarMark(face: false).frame(width: 96, height: 96)
        LurarMark(filled: false).frame(width: 96, height: 96)
        LurarMark(face: false, filled: false, primary: .primary)
            .frame(width: 18, height: 18)
    }
    .padding()
}
