import Foundation
import DubplateCore

/// Turns stored records into something the player can hold on to.
///
/// The queue never keeps SwiftData objects: they belong to a `ModelContext`, they
/// change underneath you, and the audio path must not fault objects in. Everything
/// playback needs is copied out once, here.
@MainActor
public enum QueueBuilder {

    public static func items(for release: Release) -> [PlaybackQueueItem] {
        let thumbnail = release.artwork?.thumbnailData
        return release.orderedTracks.compactMap { track in
            item(for: track, artworkThumbnail: thumbnail, releaseTitle: release.title, releaseID: release.id)
        }
    }

    public static func item(
        for track: Track,
        version: TrackVersion? = nil,
        artworkThumbnail: Data? = nil,
        releaseTitle: String? = nil,
        releaseID: UUID? = nil
    ) -> PlaybackQueueItem? {
        guard let version = version ?? track.currentVersion,
              let asset = version.audioAsset
        else {
            return nil
        }
        let release = track.release
        return PlaybackQueueItem(
            trackID: track.id,
            versionID: version.id,
            assetID: asset.id,
            relativePath: asset.relativePath,
            title: track.displayTitle,
            artistName: displayArtist(for: track),
            releaseTitle: releaseTitle ?? release?.title ?? "Inbox",
            releaseID: releaseID ?? release?.id ?? track.id,
            trackNumber: track.trackNumber,
            duration: asset.duration,
            format: asset.format,
            availability: asset.availability,
            artworkThumbnail: artworkThumbnail ?? release?.artwork?.thumbnailData,
            canvasRelativePath: track.canvas?.relativePath,
            waveformPeaks: asset.waveformPeaks
        )
    }

    /// Every version of a track as its own queue item, for the version picker.
    public static func versionItems(for track: Track) -> [PlaybackQueueItem] {
        track.orderedVersions.compactMap { item(for: track, version: $0) }
    }

    private static func displayArtist(for track: Track) -> String {
        let base = track.artistName.isEmpty ? (track.release?.artistName ?? "") : track.artistName
        guard let feature = track.featureLine else { return base }
        return base.isEmpty ? feature : "\(base) · \(feature)"
    }
}
