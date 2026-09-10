import Foundation
import SwiftData

/// Covers, looping visuals and per-track canvases.
///
/// Kept apart from the audio import because it is a different job: one file at a
/// time, replacing what is there, and every step of it decodes an image — which
/// is the thing that must never happen where a window is waiting to draw.
extension LibraryStore {

    public func setArtwork(from url: URL, for release: Release) async {
        do {
            let ingested = try await ingestor.ingestArtwork(from: url)
            let destination = mediaStore.url(forRelativePath: ingested.relativePath)
            // Reading the dimensions and building the thumbnail both decode the
            // file. A 12000px cover exported from Photoshop froze the window for
            // several seconds when that happened here, on the main actor.
            let (size, thumbnail) = await Self.artworkMetrics(at: destination)
            let asset = ArtworkAsset(
                id: ingested.assetID,
                kind: .staticArtwork,
                filename: destination.lastPathComponent,
                originalFilename: ingested.originalFilename,
                relativePath: ingested.relativePath,
                width: size.width,
                height: size.height,
                fileSize: ingested.fileSize,
                checksum: ingested.checksum
            )
            asset.thumbnailData = thumbnail
            context.insert(asset)
            if let previous = release.artwork {
                await ingestor.removeMedia(atRelativePath: previous.relativePath)
                context.delete(previous)
            }
            release.artwork = asset
            release.updatedAt = Date()
            save()
            artworkDidChange?(release.id)
        } catch let error as DubplateError {
            lastError = error
        } catch {
            lastError = DubplateError(.artworkUnreadable, subject: url.lastPathComponent, underlying: error)
        }
    }

    /// Dimensions and a thumbnail, both read off the main actor.
    nonisolated static func artworkMetrics(
        at url: URL
    ) async -> ((width: Int, height: Int), Data?) {
        await Task.detached(priority: .userInitiated) {
            (ImageInspector.pixelSize(ofFileAt: url), ImageInspector.thumbnailData(ofFileAt: url))
        }.value
    }

    public func setAnimatedArtwork(from url: URL, for release: Release) async {
        do {
            let ingested = try await ingestor.ingestArtwork(from: url)
            let asset = ArtworkAsset(
                id: ingested.assetID,
                kind: .animatedArtwork,
                filename: mediaStore.url(forRelativePath: ingested.relativePath).lastPathComponent,
                originalFilename: ingested.originalFilename,
                relativePath: ingested.relativePath,
                fileSize: ingested.fileSize,
                checksum: ingested.checksum
            )
            context.insert(asset)
            if let previous = release.animatedArtwork {
                await ingestor.removeMedia(atRelativePath: previous.relativePath)
                context.delete(previous)
            }
            release.animatedArtwork = asset
            release.updatedAt = Date()
            save()
        } catch let error as DubplateError {
            lastError = error
        } catch {
            lastError = DubplateError(.importFailed, subject: url.lastPathComponent, underlying: error)
        }
    }

    public func setCanvas(from url: URL, for track: Track) async {
        do {
            let ingested = try await ingestor.ingestArtwork(from: url)
            let asset = ArtworkAsset(
                id: ingested.assetID,
                kind: .trackVideo,
                filename: mediaStore.url(forRelativePath: ingested.relativePath).lastPathComponent,
                originalFilename: ingested.originalFilename,
                relativePath: ingested.relativePath,
                fileSize: ingested.fileSize,
                checksum: ingested.checksum
            )
            context.insert(asset)
            if let previous = track.canvas {
                await ingestor.removeMedia(atRelativePath: previous.relativePath)
                context.delete(previous)
            }
            track.canvas = asset
            track.updatedAt = Date()
            save()
        } catch let error as DubplateError {
            lastError = error
        } catch {
            lastError = DubplateError(.importFailed, subject: url.lastPathComponent, underlying: error)
        }
    }
}
