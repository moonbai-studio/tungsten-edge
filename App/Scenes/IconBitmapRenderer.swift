import AppKit

/// Renders an icon at exactly the pixel size a chip draws it, so the layer shows it 1:1.
///
/// Handing SwiftUI the multi-representation `NSImage` lets it pick a rendition by pixel count and
/// have CoreAnimation scale it bilinearly: on a 1x display a 53px slot gets the 64px 32pt@2x
/// artwork downsampled 1.2× (soft — the 发糊 reports), and an image built from one `CGImage`
/// is minified from its full size in one bilinear step (aliased — the Trash 锯齿). Rendering
/// here picks the rendition the way IconServices does (`IconRenditionChoice`) and downsamples
/// with CoreGraphics' high-quality filter into an sRGB 8-bit bitmap (the icon sources are
/// extended-sRGB float; an 8-bit context in that space cannot be created, and vImage with no
/// colour space shifts the colours).
enum IconBitmapRenderer {
    /// `appearance` selects the rendition family (the Trash is always the light one); `nil`
    /// draws in the current appearance.
    static func render(_ source: NSImage, points: CGFloat, displayScale: CGFloat, appearance: NSAppearance?) -> NSImage? {
        let reps = source.representations
        let renditions = reps.map { IconRenditionChoice.Rendition(points: $0.size.width, pixels: $0.pixelsWide) }
        guard let index = IconRenditionChoice.sourceIndex(in: renditions, points: points, displayScale: displayScale) else {
            return nil
        }
        let rep = reps[index]
        let pixels = IconRenditionChoice.pixels(points: points, displayScale: displayScale)
        var proposed = CGRect(origin: .zero, size: rep.size)
        // The ctm hint makes an IconServices rep hand back its own bitmap instead of a 1x rasterization.
        let hints: [NSImageRep.HintKey: Any] = [.ctm: AffineTransform(scale: renditions[index].scale)]
        var sourceImage: CGImage?
        let draw = { sourceImage = rep.cgImage(forProposedRect: &proposed, context: nil, hints: hints) }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        guard let sourceImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let bitmap = context.makeImage() else { return nil }
        // Point size = pixels / scale, not `points`: the layer rounds its bounds to the pixel grid
        // the same way, which is what keeps the mapping 1:1.
        let pointSize = NSSize(width: CGFloat(pixels) / displayScale, height: CGFloat(pixels) / displayScale)
        let image = NSImage(size: pointSize)
        let bitmapRep = NSBitmapImageRep(cgImage: bitmap)
        bitmapRep.size = pointSize
        image.addRepresentation(bitmapRep)
        return image
    }
}

/// Rendered bitmaps per icon and pixel size. A plain dictionary, never `NSCache` (same reason as
/// `AppIconResolver`: `NSCache` evicts constantly and a render costs 1–5ms on every body pass).
/// Main-thread only (SwiftUI body / bitmap snapshot).
@MainActor
final class IconBitmapCache {
    private struct Key: Hashable {
        let name: String
        let pixels: Int
        let appearance: String
    }

    private var bitmaps: [Key: NSImage] = [:]
    /// Rendered pixel sizes per icon, for the stand-in lookup while rendering is paused.
    private var renderedSizes: [String: [Int]] = [:]

    func removeAll(name: String) {
        let keys = bitmaps.keys.filter { $0.name == name }
        for key in keys {
            bitmaps.removeValue(forKey: key)
            renderedSizes.removeValue(forKey: key.name + "|" + key.appearance)
        }
    }

    /// `allowsRendering == false` (a height drag in progress, where every tick is a new size)
    /// returns the nearest size already rendered and lets the layer scale it; the first request
    /// for an icon still renders, so nothing is ever drawn from the unrendered source.
    func image(name: String, points: CGFloat, displayScale: CGFloat, appearance: NSAppearance?,
               allowsRendering: Bool, source: () -> NSImage) -> NSImage {
        let appearanceName = appearance?.name.rawValue ?? ""
        let pixels = IconRenditionChoice.pixels(points: points, displayScale: displayScale)
        let key = Key(name: name, pixels: pixels, appearance: appearanceName)
        if let cached = bitmaps[key] { return cached }
        let sizesKey = name + "|" + appearanceName
        if !allowsRendering,
           let standIn = IconRenditionChoice.standInPixels(rendered: renderedSizes[sizesKey] ?? [], target: pixels),
           let cached = bitmaps[Key(name: name, pixels: standIn, appearance: appearanceName)] {
            return cached
        }
        let original = source()
        guard let rendered = IconBitmapRenderer.render(original, points: points, displayScale: displayScale, appearance: appearance) else {
            return original
        }
        if bitmaps.count >= 256 {   // growth guard only; a session sees a few sizes per icon
            bitmaps.removeAll()
            renderedSizes.removeAll()
        }
        bitmaps[key] = rendered
        renderedSizes[sizesKey, default: []].append(pixels)
        return rendered
    }
}
