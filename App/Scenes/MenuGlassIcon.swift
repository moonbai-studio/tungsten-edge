import AppKit
import SwiftUI

/// A two-layer "frosted glass" glyph for the status menu's toggle tiles: a solid back shape,
/// a translucent front shape that frosts whatever of the back it covers, and white details on
/// the glass. Shapes are authored on a 24×24 grid and drawn as vectors, so 1x and 2x both stay sharp.
struct MenuGlassGlyph {
    let back: @Sendable (inout Path) -> Void
    let front: @Sendable (inout Path) -> Void
    let detail: @Sendable (inout Path) -> Void

    static let shelf = MenuGlassGlyph(
        back: { roundedRect(&$0, 6.5, 2.5, 11, 12, 2) },
        front: { roundedRect(&$0, 2, 10, 20, 11.5, 3.2) },
        detail: { line(&$0, 8.5, 14.5, 15.5, 14.5) }
    )

    static let trash = MenuGlassGlyph(
        back: {
            roundedRect(&$0, 3, 4.2, 18, 3.6, 1.8)
            roundedRect(&$0, 9, 1.8, 6, 4, 1.4)
        },
        front: { roundedRect(&$0, 5, 6.4, 14, 15.6, 2.8) },
        detail: {
            line(&$0, 10, 10.5, 10, 17.5)
            line(&$0, 14, 10.5, 14, 17.5)
        }
    )

    static let hoverName = MenuGlassGlyph(
        back: { roundedRect(&$0, 10, 2, 12, 10, 3) },
        front: {
            roundedRect(&$0, 2, 7, 16, 11.5, 3.4)
            $0.move(to: CGPoint(x: 5, y: 17))
            $0.addLine(to: CGPoint(x: 5.2, y: 21.6))
            $0.addLine(to: CGPoint(x: 10, y: 17))
            $0.closeSubpath()
        },
        detail: {
            line(&$0, 6, 11, 14, 11)
            line(&$0, 6, 14.3, 11.5, 14.3)
        }
    )

    static let avoidTaskbar = MenuGlassGlyph(
        back: { roundedRect(&$0, 2, 17.2, 20, 4.3, 2.1) },
        front: { roundedRect(&$0, 4, 2.5, 16, 15.7, 2.8) },
        detail: {
            line(&$0, 12, 14, 12, 7)
            line(&$0, 9, 10, 12, 7)
            line(&$0, 15, 10, 12, 7)
        }
    )

    /// Not a toggle: the icon in front of the "Single/Multi-Display Mode" title.
    static let displays = MenuGlassGlyph(
        back: {
            roundedRect(&$0, 10, 2.5, 12, 9, 2.2)
            roundedRect(&$0, 7.5, 16.5, 4, 4, 0.8)
            roundedRect(&$0, 5.5, 19.6, 8, 2, 1)
        },
        front: { roundedRect(&$0, 2, 7, 15, 10.5, 2.5) },
        detail: { _ in }
    )

    /// The "Single/Multi-Display Mode" submenu: one screen for the single-display modes, two for
    /// the multi-display ones; the bar is the solid back layer.
    static let followMouse = MenuGlassGlyph(
        back: { roundedRect(&$0, 4, 14, 16, 6, 3) },
        front: { roundedRect(&$0, 2, 2.5, 20, 15, 2.8) },
        detail: {
            $0.move(to: CGPoint(x: 9, y: 5))
            $0.addLine(to: CGPoint(x: 9, y: 12.6))
            $0.addLine(to: CGPoint(x: 10.9, y: 10.9))
            $0.addLine(to: CGPoint(x: 12.3, y: 13.8))
            $0.addLine(to: CGPoint(x: 13.5, y: 13.2))
            $0.addLine(to: CGPoint(x: 12.1, y: 10.3))
            $0.addLine(to: CGPoint(x: 14.6, y: 10.1))
            $0.closeSubpath()
        }
    )

    static let pinnedScreen = MenuGlassGlyph(
        back: { roundedRect(&$0, 4, 14, 16, 6, 3) },
        front: { roundedRect(&$0, 2, 2.5, 20, 15, 2.8) },
        detail: {
            $0.addEllipse(in: CGRect(x: 9.8, y: 5, width: 4.4, height: 4.4))
            line(&$0, 12, 9.4, 12, 13)
        }
    )

    /// One bar running under both screens: the same bar everywhere.
    static let mirroredBars = MenuGlassGlyph(
        back: { roundedRect(&$0, 2.5, 11.5, 19, 7, 3) },
        front: {
            roundedRect(&$0, 1, 4, 9.5, 9, 2)
            roundedRect(&$0, 13.5, 4, 9.5, 9, 2)
        },
        detail: { _ in }
    )

    /// A bar of its own under each screen, of different lengths.
    static let perDisplayBars = MenuGlassGlyph(
        back: {
            roundedRect(&$0, 2, 11.5, 8, 7, 3)
            roundedRect(&$0, 15.5, 11.5, 6, 7, 3)
        },
        front: {
            roundedRect(&$0, 1, 4, 9.5, 9, 2)
            roundedRect(&$0, 13.5, 4, 9.5, 9, 2)
        },
        detail: { _ in }
    )

    private static func roundedRect(_ path: inout Path, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) {
        path.addRoundedRect(
            in: CGRect(x: x, y: y, width: width, height: height),
            cornerSize: CGSize(width: radius, height: radius),
            style: .continuous
        )
    }

    private static func line(_ path: inout Path, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        path.move(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x2, y: y2))
    }
}

private struct GridShape: Shape {
    let build: @Sendable (inout Path) -> Void

    func path(in rect: CGRect) -> Path {
        var path = Path()
        build(&path)
        let scale = rect.width / 24
        return path
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The tint and dark flag arrive already resolved (see `MenuToggleTile.applyState`): a dynamic
/// `NSColor` handed to SwiftUI compares equal across appearance changes, so the hosting view
/// would keep the old colours.
struct MenuGlassIconView: View {
    /// The owner's pick, fixed on purpose: the glyphs do not follow the system accent colour.
    static let blue = NSColor(srgbRed: 32 / 255, green: 73 / 255, blue: 236 / 255, alpha: 1)
    /// Dark appearance only: the dark menu's backdrop swings from mid grey to near black with
    /// whatever is behind it, and glass mixed from white and the blue goes a muddy violet on both.
    /// A light glass of its own keeps the front and back apart instead.
    static let darkGlassBlue = NSColor(srgbRed: 165 / 255, green: 192 / 255, blue: 1, alpha: 1)

    let glyph: MenuGlassGlyph
    let size: CGFloat
    let tint: Color
    /// The front layer's colour in the dark appearance (unused in light).
    let darkGlass: Color
    let isDark: Bool
    /// On a highlighted menu row: all white, details cut out, so the highlight shows through.
    var onHighlight = false

    var body: some View {
        // At menu-row size the blur only smears the two layers into one blob.
        let isSimplified = isDark && size < 20
        let back = GridShape(build: glyph.back)
        let front = GridShape(build: glyph.front)
        let frontBox = front.path(in: CGRect(x: 0, y: 0, width: size, height: size)).boundingRect
        let frontCenter = UnitPoint(x: frontBox.midX / size, y: frontBox.midY / size)
        let melted = back.fill(tint)
            .scaleEffect(1.04, anchor: frontCenter)
            .offset(y: size * 0.015)
            .blur(radius: size * 0.065)
        ZStack {
            // The back shape stops at the glass: the glass is translucent, so a sharp back drawn
            // underneath would show its edge through the frost.
            back.fill(tint)
                .mask(
                    ZStack {
                        Rectangle()
                        front.fill(Color.black).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                )
            ZStack {
                // Milky glass, then the back shape blurred into it. The blur stays small enough
                // that the back's outline is still readable: a large one turns it into a shapeless
                // glow. The magnify-and-shift is the refraction. Dark glass is lighter, or the
                // blurred shape sinks into it.
                if onHighlight {
                    front.fill(Color.white.opacity(0.40))
                } else if isDark {
                    front.fill(darkGlass.opacity(0.72))
                } else {
                    front.fill(Color.white.opacity(0.88))
                    front.fill(tint.opacity(0.27))
                }
                if !isSimplified { melted }
            }
            .mask(front.fill(Color.white))
            GridShape(build: glyph.detail)
                .stroke(Color.white, style: StrokeStyle(lineWidth: size / (isSimplified ? 11 : 16), lineCap: .round, lineJoin: .round))
                .blendMode(onHighlight ? .destinationOut : .normal)
        }
        .compositingGroup()
        .frame(width: size, height: size)
    }
}

extension MenuGlassIconView {
    /// A bitmap with 1x and 2x representations, so neither screen scales it. `ImageRenderer` is
    /// macOS 13+; macOS 12 gets `nil` and the caller goes without the icon.
    @MainActor
    func bitmapImage() -> NSImage? {
        guard #available(macOS 13, *) else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size))
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: self)
            renderer.scale = scale
            guard let cgImage = renderer.cgImage else { return nil }
            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = image.size
            image.addRepresentation(rep)
        }
        return image
    }
}
