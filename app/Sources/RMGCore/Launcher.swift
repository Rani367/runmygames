import AppKit
import Foundation

/// Creates ~/Applications/RunMyGames/<Game>.app so each Windows game shows up in
/// Launchpad, Spotlight and the Dock like a native Mac app.
public struct LauncherFactory: Sendable {
    public let paths: Paths
    public init(paths: Paths = .shared) { self.paths = paths }

    /// The `rmg` binary the launcher calls: inside the installed app, or the current one.
    public var rmgBinary: String {
        let installed = "/Applications/RunMyGames.app/Contents/MacOS/rmg"
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        return URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    public func appURL(for game: Game) -> URL {
        let safe = game.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        return paths.launchers.appendingPathComponent("\(safe).app")
    }

    public func existing(_ id: Int) -> URL? {
        let fm = FileManager.default
        let apps = (try? fm.contentsOfDirectory(at: paths.launchers, includingPropertiesForKeys: nil)) ?? []
        return apps.first {
            let plist = NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist"))
            return plist?["RMGAppID"] as? Int == id
        }
    }

    @discardableResult
    public func create(for game: Game, artwork: URL?) async throws -> URL {
        let fm = FileManager.default
        if let old = existing(game.id) { try? fm.removeItem(at: old) }
        let app = appURL(for: game)
        let contents = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)

        let script = """
        #!/bin/sh
        # RunMyGames launcher for \(game.name.replacingOccurrences(of: "\n", with: " ")) (Steam app \(game.id))
        RMG="\(rmgBinary)"
        [ -x "$RMG" ] || RMG="/Applications/RunMyGames.app/Contents/MacOS/rmg"
        exec "$RMG" launch \(game.id) --watch
        """
        let exe = contents.appendingPathComponent("MacOS/launch")
        try script.write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let info: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": "dev.runmygames.game.\(game.id)",
            "CFBundleName": game.name,
            "CFBundleDisplayName": game.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleIconFile": "AppIcon",
            "LSApplicationCategoryType": "public.app-category.games",
            "LSUIElement": true, // the game itself appears in the Dock, not this stub
            "RMGAppID": game.id,
        ]
        (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)

        // Portrait capsule (cached or from Steam's CDN) makes the best square icon; the
        // wide header is the last resort.
        var art = SteamLibrary(paths: paths).artwork(game.id, portraitOnly: true)
        if art == nil { art = try? await download(SteamLibrary.artworkCDN(game.id)) }
        if art == nil { art = artwork }
        if let art, let icon = IconMaker.icns(from: art) {
            try icon.write(to: contents.appendingPathComponent("Resources/AppIcon.icns"))
        }
        // Ad-hoc sign so Gatekeeper/Launch Services treat it as a regular local app.
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["-f", "-s", "-", app.path]
        cs.standardError = FileHandle.nullDevice
        try? cs.run(); cs.waitUntilExit()
        // Refresh Finder/Launchpad icon cache.
        NSWorkspace.shared.noteFileSystemChanged(app.path)
        return app
    }

    public func remove(_ id: Int) {
        if let u = existing(id) { try? FileManager.default.removeItem(at: u) }
    }

    private func download(_ url: URL) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RMGError.failed("no artwork") }
        return tmp
    }
}

/// Builds a macOS-style rounded-square .icns from Steam capsule art.
public enum IconMaker {
    public static func icns(from imageURL: URL) -> Data? {
        guard let src = NSImage(contentsOf: imageURL),
              let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let fm = FileManager.default
        let set = fm.temporaryDirectory.appendingPathComponent("rmg-\(UUID().uuidString).iconset")
        try? fm.createDirectory(at: set, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: set) }
        for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                           (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"),
                           (1024, "512x512@2x")] {
            guard let png = render(cg, size: px) else { return nil }
            try? png.write(to: set.appendingPathComponent("icon_\(name).png"))
        }
        let out = set.deletingPathExtension().appendingPathExtension("icns")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", set.path, "-o", out.path]
        try? p.run(); p.waitUntilExit()
        defer { try? fm.removeItem(at: out) }
        return try? Data(contentsOf: out)
    }

    /// Apple's icon grid: ~80% body with continuous-corner rounding; art fills the body (aspect-fill).
    static func render(_ img: CGImage, size: Int) -> Data? {
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let inset = s * 0.1
        let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path); ctx.clip()
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        ctx.interpolationQuality = .high
        if iw > ih * 1.2 {
            // Wide header art: a dimmed, enlarged copy fills the square, the full image sits centered.
            let fill = max(body.width / iw, body.height / ih) * 1.15
            ctx.setAlpha(0.45)
            ctx.draw(img, in: CGRect(x: body.midX - iw * fill / 2, y: body.midY - ih * fill / 2, width: iw * fill, height: ih * fill))
            ctx.setAlpha(1)
            let fit = body.width / iw
            ctx.draw(img, in: CGRect(x: body.minX, y: body.midY - ih * fit / 2, width: body.width, height: ih * fit))
        } else {
            // Portrait capsules have the logo in the upper part; bias the crop upward.
            let scale = max(body.width / iw, body.height / ih)
            let w = iw * scale, h = ih * scale
            ctx.draw(img, in: CGRect(x: body.midX - w / 2, y: body.maxY - h + (h - body.height) * 0.3, width: w, height: h))
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}
