import AppKit
import ImageIO
import RMGCore

/// A decoded image handed out of the cache. NSImage is only Sendable in newer SDKs; these are
/// never mutated after decoding, so sharing them across threads is safe.
struct DecodedImage: @unchecked Sendable {
    let image: NSImage
}

/// Decoded, downscaled artwork shared by every card. Loading happens off the main thread and
/// only once per image, so scrolling and hovering never touch the disk or network.
actor ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()
    private var failedRemote = Set<URL>()

    /// Steam's cached artwork if there is any, else the public CDN.
    func artwork(id: Int, local: URL?, maxPixel: Int = 600) async -> DecodedImage? {
        let key = "\(id)|\(local?.path ?? "cdn")" as NSString
        if let hit = cache.object(forKey: key) { return DecodedImage(image: hit) }
        var image: NSImage?
        if let local { image = Self.decode(try? Data(contentsOf: local), maxPixel: maxPixel) }
        if image == nil {
            for url in SteamLibrary.artworkCDN(id) where image == nil && !failedRemote.contains(url) {
                if let data = try? await Downloader.data(url) {
                    image = Self.decode(data, maxPixel: maxPixel)
                } else {
                    failedRemote.insert(url)
                }
            }
        }
        guard let image else { return nil }
        cache.setObject(image, forKey: key)
        return DecodedImage(image: image)
    }

    private static func decode(_ data: Data?, maxPixel: Int) -> NSImage? {
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
