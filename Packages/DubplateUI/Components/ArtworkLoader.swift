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
@Observable
public final class ArtworkLoader {
    private let mediaStore: MediaStore
    private let cache = NSCache<NSString, DubplateImage>()
    private var inFlight: [String: Task<DubplateImage?, Never>] = [:]

    public init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        cache.countLimit = 240
    }

    /// Cached image, if it is already decoded. Views call this first so a scroll
    /// never flashes a placeholder for art it has already seen.
    public func cachedImage(for asset: ArtworkAsset?, edge: CGFloat) -> DubplateImage? {
        guard let asset, !asset.relativePath.isEmpty else { return nil }
        return cache.object(forKey: key(asset.relativePath, edge) as NSString)
    }

    public func image(for asset: ArtworkAsset?, edge: CGFloat) async -> DubplateImage? {
        guard let asset, !asset.relativePath.isEmpty else { return nil }
        let cacheKey = key(asset.relativePath, edge)
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached }

        if let existing = inFlight[cacheKey] { return await existing.value }

        let url = mediaStore.url(forRelativePath: asset.relativePath)
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
            cache.setObject(image, forKey: cacheKey as NSString)
        }
        return image
    }

    /// Drops cached renditions of one asset, after its artwork is replaced.
    public func invalidate(relativePath: String) {
        for edge in Self.commonEdges {
            cache.removeObject(forKey: key(relativePath, edge) as NSString)
        }
    }

    public func invalidateAll() {
        cache.removeAllObjects()
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
