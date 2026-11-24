import AppKit

enum CameraStatusImage {
    static func make(onAir: Bool, configuration: NSImage.SymbolConfiguration? = nil,
                     outlineColor: NSColor = .labelColor) -> NSImage {
        let symbol = NSImage(systemSymbolName: "video", accessibilityDescription: nil)!
        let outline = configuration.flatMap { symbol.withSymbolConfiguration($0) } ?? symbol
        guard onAir else { return outline }

        let solid = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)!
        let interior = configuration.flatMap { solid.withSymbolConfiguration($0) } ?? solid
        let fill = interior.withSymbolConfiguration(.init(paletteColors: [.systemRed]))!
        let stroke = outline.withSymbolConfiguration(.init(paletteColors: [outlineColor]))!
        let edgeMask = outline.withSymbolConfiguration(.init(paletteColors: [.white]))!
        let image = NSImage(size: outline.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Remove red underneath the native stroke so its translucent shade
            // matches the idle outline even on a dark menu bar.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            fill.draw(in: rect)
            edgeMask.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
            context.endTransparencyLayer()
            stroke.draw(in: rect)
            return true
        }
        image.cacheMode = .never
        image.isTemplate = false
        return image
    }
}
