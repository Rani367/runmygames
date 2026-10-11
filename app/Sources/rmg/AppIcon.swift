import AppKit

/// Renders the RunMyGames app icon artwork (gradient + controller symbol) to a temporary PNG.
enum AppIcon {
    static func png() -> URL? {
        let size = 1024.0
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let gradient = NSGradient(colors: [NSColor(red: 0.36, green: 0.27, blue: 0.95, alpha: 1),
                                               NSColor(red: 0.85, green: 0.25, blue: 0.55, alpha: 1)])
            gradient?.draw(in: rect, angle: -60)
            let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 20, width: s.width, height: s.height))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rmg-appicon.png")
        try? data.write(to: url)
        return url
    }
}
