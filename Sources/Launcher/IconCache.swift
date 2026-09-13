import AppKit

/// Row icons, rasterized once into 64 px bitmaps (32 pt @2x) so that no full-size
/// icon representations stay in memory. Bounded by an `NSCache`, and loaded off
/// the main thread: a row shows a blank icon until its icon is ready.
@MainActor
final class IconCache {
    nonisolated static let pointSize: CGFloat = 32
    nonisolated static let pixelSize = 64

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()
    private var waiting: [IconSource: [@MainActor (NSImage) -> Void]] = [:]
    private let queue = DispatchQueue(label: "alauncher.icons", qos: .userInitiated)

    /// The icon if it's cached. Otherwise nil, and `completion` gets it on the main
    /// thread once it's drawn.
    func icon(for source: IconSource, completion: @escaping @MainActor (NSImage) -> Void) -> NSImage? {
        let key = Self.key(for: source)
        if let image = cache.object(forKey: key) { return image }
        if waiting[source] != nil {
            waiting[source]?.append(completion)
            return nil
        }
        waiting[source] = [completion]
        queue.async {
            let rendered = RenderedIcon(image: IconRenderer.render(source))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(source, rendered.image) }
            }
        }
        return nil
    }

    /// Starts loading icons that will probably be shown soon.
    func prefetch(_ sources: [IconSource]) {
        for source in sources {
            _ = icon(for: source) { _ in }
        }
    }

    private func finish(_ source: IconSource, _ image: NSImage) {
        cache.setObject(image, forKey: Self.key(for: source))
        let completions = waiting.removeValue(forKey: source) ?? []
        for completion in completions {
            completion(image)
        }
    }

    private static func key(for source: IconSource) -> NSString {
        switch source {
        case .file(let path): return "file:\(path)" as NSString
        case .glyph(let text): return "glyph:\(text)" as NSString
        case .image(let path, let fallback): return "image:\(path)|\(fallback)" as NSString
        case .symbol(let name): return "symbol:\(name)" as NSString
        case .calculator: return "calculator" as NSString
        }
    }
}

/// A finished image handed from the icon queue to the main thread. It isn't
/// touched again on the queue after the handoff.
private struct RenderedIcon: @unchecked Sendable {
    let image: NSImage
}

/// Draws icons into small bitmaps. Runs on the icon queue.
enum IconRenderer {
    static func render(_ source: IconSource) -> NSImage {
        switch source {
        case .file(let path):
            return rasterize(NSWorkspace.shared.icon(forFile: path))
        case .image(let path, let fallback):
            if let image = NSImage(contentsOfFile: path), image.isValid {
                return rasterize(image)
            }
            return rasterize(NSWorkspace.shared.icon(forFile: fallback))
        case .glyph(let text):
            return glyph(text)
        case .symbol(let name):
            return symbol(name)
        case .calculator:
            return symbol("equal.square.fill")
        }
    }

    /// Only the 64 px bitmap is kept; setting `size` on the original would keep
    /// every large representation alive.
    static func rasterize(_ image: NSImage) -> NSImage {
        draw { rect in
            // Aspect-fit, so a non-square script image isn't stretched.
            let size = image.size
            guard size.width > 0, size.height > 0 else { return }
            let scale = min(rect.width / size.width, rect.height / size.height)
            let fitted = NSSize(width: size.width * scale, height: size.height * scale)
            let target = NSRect(x: (rect.width - fitted.width) / 2, y: (rect.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// An emoji, drawn in color. Other text is drawn as a template, so it follows the appearance.
    static func glyph(_ text: String) -> NSImage {
        let isEmoji = text.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        let image = draw { rect in
            var fontSize: CGFloat = 46
            var string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
            let width = string.size().width
            if width > rect.width {
                fontSize *= rect.width / width
                string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
            }
            let size = string.size()
            string.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
        }
        image.isTemplate = !isEmoji
        return image
    }

    /// SF Symbols are drawn as templates, tinted by the row.
    static func symbol(_ name: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return draw { _ in }
        }
        let image = draw { rect in
            let size = symbol.size
            let scale = min(44 / max(size.width, 1), 44 / max(size.height, 1))
            let drawn = NSSize(width: size.width * scale, height: size.height * scale)
            symbol.draw(in: NSRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        image.isTemplate = true
        return image
    }

    /// Draws into a fresh 64×64 bitmap in pixel coordinates, then presents it as 32 pt.
    static func draw(_ body: (NSRect) -> Void) -> NSImage {
        let pixels = IconCache.pixelSize
        let points = NSSize(width: IconCache.pointSize, height: IconCache.pointSize)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return NSImage(size: points)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        body(NSRect(x: 0, y: 0, width: pixels, height: pixels))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        bitmap.size = points
        let image = NSImage(size: points)
        image.addRepresentation(bitmap)
        return image
    }
}
