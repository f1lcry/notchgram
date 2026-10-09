import AppKit
import ImageIO
import SwiftUI

/// Decoded-image cache, keyed by file path and target pixel size.
///
/// Session 1 called `NSImage(contentsOf:)` inside computed properties — a full
/// re-read and re-decode of the original file on **every body evaluation of
/// every bubble**, at full resolution, uncached. In a media chat that alone
/// accounts for gigabytes of transient allocations and a saturated main
/// thread. Everything image-shaped now goes through here: decoded once, at the
/// size it will be drawn, off the main thread, and kept under a byte budget.
@MainActor
enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 192 * 1024 * 1024
        // The cost limit is advisory; the count limit is the hard backstop
        // against decode churn outrunning eviction during a fast scroll.
        cache.countLimit = 512
        _ = pressureSource
        return cache
    }()

    /// System memory pressure empties both image caches outright — everything
    /// in them is re-decodable from disk.
    private static let pressureSource: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                ImageCache.removeAll()
                MinithumbCache.removeAll()
            }
        }
        source.activate()
        return source
    }()

    static func removeAll() {
        cache.removeAllObjects()
    }

    private static func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.path)#\(Int(maxPixel))" as NSString
    }

    static func cached(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    static func store(_ image: NSImage, url: URL, maxPixel: CGFloat) {
        let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh }
            ?? Int(image.size.width * image.size.height)
        cache.setObject(image, forKey: key(url, maxPixel), cost: pixels * 4)
    }

    /// Decode-and-downsample, off the main actor. `CGImageSourceCreateThumbnail`
    /// never inflates the full bitmap when a max pixel size is given, which is
    /// the difference between a 12 MP photo costing 45 MB or 1 MB of RAM.
    nonisolated static func decode(url: URL, maxPixel: CGFloat) async -> sending NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel),
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

/// Tiny cache for inline minithumbnails (the ~40-pixel JPEGs TDLib embeds in
/// chats and messages). They are re-rendered constantly — every list pass —
/// and decoding a Data per body adds up across 40 rows.
@MainActor
enum MinithumbCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 1024
        return cache
    }()

    static func removeAll() {
        cache.removeAllObjects()
    }

    static func image(for data: Data) -> NSImage? {
        // Hash the FULL payload: minithumbnails all come from one encoder, so
        // any short prefix (and Foundation's own `Data.hashValue`, which only
        // reads a prefix) collides across files of equal length — the cause of
        // avatars bleeding between chats.
        var hasher = Hasher()
        data.withUnsafeBytes { hasher.combine(bytes: $0) }
        let key = "\(data.count)-\(hasher.finalize())" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: data.count * 32)
        return image
    }
}

/// A downloaded image at display size: synchronous when cached, async decode
/// with a caller-supplied placeholder when not.
struct MediaImage<Placeholder: View>: View {
    let url: URL?
    /// Target size in points; the decode target is `max(w, h) × displayScale`.
    let targetSize: CGSize
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var decoded: NSImage?

    private var maxPixel: CGFloat {
        max(targetSize.width, targetSize.height) * max(displayScale, 1)
    }

    var body: some View {
        Group {
            if let image = decoded ?? url.flatMap({ ImageCache.cached($0, maxPixel: maxPixel) }) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: taskKey) {
            // `decoded` must never outlive its URL: this view is reused across
            // chat/message switches, and a stale value here painted the
            // previous peer's photo over the new one (or over "no photo").
            guard let url else {
                decoded = nil
                return
            }
            if let cached = ImageCache.cached(url, maxPixel: maxPixel) {
                decoded = cached
                return
            }
            decoded = nil
            guard let image = await ImageCache.decode(url: url, maxPixel: maxPixel) else { return }
            guard !Task.isCancelled else { return }
            ImageCache.store(image, url: url, maxPixel: maxPixel)
            decoded = image
        }
    }

    private var taskKey: String {
        "\(url?.path ?? "-")#\(Int(maxPixel))"
    }
}
