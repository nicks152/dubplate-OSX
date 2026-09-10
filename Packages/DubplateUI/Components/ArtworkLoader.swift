import SwiftUI
import Observation
import DubplateCore

/// Loads and caches cover art.
///
/// Decoding happens off the main actor at the size it will be drawn, so scrolling a
/// library of 4000px covers never decodes a 4000px bitmap. The cache is an
/// `NSCache`, which means the system evicts it under pressure rather than Dubplate
/// guessing when to.
@MainActor
public final class ArtworkLoader {
    private let mediaStore: MediaStore
    private let cache = NSCache<NSString, DubplateImage>()
    private var inFlight: [String: Task<DubplateImage?, Never>] = [:]
    /// Paths whose bytes are on this device and will not decode.
    ///
    /// Without this a corrupt or truncated cover was re-decoded on every pass of
    /// the grid — ImageIO failing over and over, for the life of the session, at
    /// scroll rate. Cleared whenever the artwork is replaced. A file that is
    /// merely absent is never recorded here: it will decode once it arrives.
    private var undecodable: Set<String> = []

    public init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        cache.countLimit = 240
        // A 2048px cover is 16 MB decoded, so a count limit alone allows a gigabyte
        // of bitmaps. 96 MB is generous for a grid and survivable on a phone.
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    /// Cached image, if it is already decoded. Views call this first so a scroll
    /// never flashes a placeholder for art it has already seen.
    public func cachedImage(for asset: ArtworkAsset?, edge: CGFloat) -> DubplateImage? {
        guard let asset, !asset.relativePath.isEmpty else { return nil }
        return cache.object(forKey: key(asset.relativePath, edge) as NSString)
    }

    /// Whether asking again could only fail again. Views use it to go straight to
    /// the monogram instead of holding a spinner over a file that is never coming.
    public func isUndecodable(_ asset: ArtworkAsset?) -> Bool {
        guard let asset else { return false }
        return undecodable.contains(asset.relativePath)
    }

    public func image(for asset: ArtworkAsset?, edge: CGFloat) async -> DubplateImage? {
        guard let asset, !asset.relativePath.isEmpty else { return nil }
        guard !undecodable.contains(asset.relativePath) else { return nil }
        let cacheKey = key(asset.relativePath, edge)
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached }

        if let existing = inFlight[cacheKey] { return await existing.value }

        let path = asset.relativePath
        let url = mediaStore.url(forRelativePath: path)
        let bytesAreHere = mediaStore.exists(relativePath: path)
        let thumbnail = asset.thumbnailData
        let maxPixel = Int(edge * displayScale)

        let task = Task<DubplateImage?, Never> {
            await Task.detached(priority: .userInitiated) { () -> DubplateImage? in
                if let cgImage = ImageInspector.cgImage(ofFileAt: url, maxPixel: maxPixel) {
                    return DubplateImage.make(from: cgImage)
                }
                // The file is not on this device yet (or has gone missing). The
                // stored thumbnail still lets the record look like a record.
                if let thumbnail, let image = DubplateImage(data: thumbnail) {
                    return image
                }
                return nil
            }.value
        }
        inFlight[cacheKey] = task
        let image = await task.value
        inFlight[cacheKey] = nil
        if let image {
            cache.setObject(image, forKey: cacheKey as NSString, cost: cost(of: image))
        } else if bytesAreHere {
            // The file is here and neither it nor its thumbnail decoded. Trying
            // again on the next scroll pass would fail in exactly the same way.
            undecodable.insert(path)
        }
        return image
    }

    /// Drops cached renditions of one asset, after its artwork is replaced.
    public func invalidate(relativePath: String) {
        undecodable.remove(relativePath)
        for edge in Self.commonEdges {
            cache.removeObject(forKey: key(relativePath, edge) as NSString)
        }
    }

    public func invalidateAll() {
        undecodable.removeAll()
        cache.removeAllObjects()
    }

    /// Roughly the bytes a decoded image occupies.
    private func cost(of image: DubplateImage) -> Int {
        #if os(iOS)
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        #else
        let pixels = Int(image.size.width * image.size.height)
        #endif
        return max(1, pixels * 4)
    }

    /// Renditions are bucketed so a resize does not decode a new image per point.
    private func key(_ path: String, _ edge: CGFloat) -> String {
        "\(path)@\(bucket(for: edge))"
    }

    private func bucket(for edge: CGFloat) -> Int {
        Self.commonEdges.first { edge <= $0 } ?? Self.commonEdges.last ?? 512
    }

    private static let commonEdges: [CGFloat] = [64, 128, 256, 512, 1024, 2048]

    private var displayScale: CGFloat {
        #if os(iOS)
        return UIScreen.main.scale
        #else
        return NSScreen.main?.backingScaleFactor ?? 2
        #endif
    }
}
