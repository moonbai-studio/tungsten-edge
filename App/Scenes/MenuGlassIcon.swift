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

    let glyph: MenuGlassGlyph
    let size: CGFloat
    let tint: Color
    let isDark: Bool

    var body: some View {
        let back = GridShape(build: glyph.back)
        let front = GridShape(build: glyph.front)
        let frontBox = front.path(in: CGRect(x: 0, y: 0, width: size, height: size)).boundingRect
        let frontCenter = UnitPoint(x: frontBox.midX / size, y: frontBox.midY / size)
        ZStack {
            back.fill(tint)
            ZStack {
                // Diffusion: the colour behind spreads out through the frost.
                back.fill(tint).blur(radius: size * 0.16).opacity(0.85)
                // Refraction: seen through the glass the back shape is magnified and shifted, so
                // its edge does not line up with the part outside the glass.
                back.fill(tint)
                    .scaleEffect(1.10, anchor: frontCenter)
                    .offset(y: size * 0.035)
                    .blur(radius: size * 0.07)
                front.fill(Color.white.opacity(isDark ? 0.26 : 0.50))
                front.fill(tint.opacity(isDark ? 0.30 : 0.24))
                // Rim light: a wide blurred stroke whose outer half the mask cuts away, bright at
                // the top-left and gone by the bottom-right. A plain hairline reads as a hard edge.
                front
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(isDark ? 0.32 : 0.50), Color.white.opacity(0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: size / 14
                    )
                    .blur(radius: size / 32)
            }
            .mask(front.fill(Color.white))
            GridShape(build: glyph.detail)
                .stroke(Color.white, style: StrokeStyle(lineWidth: size / 16, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}
