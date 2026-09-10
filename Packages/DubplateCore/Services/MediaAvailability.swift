import Foundation
import SwiftData

/// Works out what is actually on this device.
///
/// Availability is not stored and not synced — see `AudioAsset.localPresence`. It is
/// established by looking, which is cheap: `FileManager.fileExists` on a few hundred
/// paths costs less than a scroll frame, and it can never be wrong the way a synced
/// flag can.
@MainActor
public enum MediaAvailability {

    /// Refreshes every asset on a release. Called when a release is opened and after
    /// a transfer settles.
    public static func refresh(_ release: Release, using store: MediaStore) {
        for track in release.orderedTracks {
            for version in track.versions ?? [] {
                if let asset = version.audioAsset {
                    refresh(asset, using: store)
                }
            }
            if let canvas = track.canvas {
                refresh(canvas, using: store)
            }
        }
        if let artwork = release.artwork { refresh(artwork, using: store) }
        if let motion = release.animatedArtwork { refresh(motion, using: store) }
    }

    public static func refresh(_ asset: AudioAsset, using store: MediaStore) {
        let present = store.exists(relativePath: asset.relativePath)
        asset.localPresence = present
        if present, asset.transferState == .downloading || asset.transferState == .error {
            asset.transferState = nil
        }
    }

    public static func refresh(_ asset: ArtworkAsset, using store: MediaStore) {
        asset.localPresence = store.exists(relativePath: asset.relativePath)
    }

    /// Every asset in the library, for the pass that runs once at launch.
    public static func refreshAll(in context: ModelContext, using store: MediaStore) {
        let audio = (try? context.fetch(FetchDescriptor<AudioAsset>())) ?? []
        for asset in audio { refresh(asset, using: store) }
        let artwork = (try? context.fetch(FetchDescriptor<ArtworkAsset>())) ?? []
        for asset in artwork { refresh(asset, using: store) }
    }

    /// The current versions of a release that are not on this device yet.
    public static func missingAssetIDs(for release: Release, using store: MediaStore) -> [UUID] {
        var identifiers: [UUID] = []
        for track in release.orderedTracks {
            guard let asset = track.currentAsset else { continue }
            if !store.exists(relativePath: asset.relativePath) {
                identifiers.append(asset.id)
            }
        }
        if let artwork = release.artwork, !store.exists(relativePath: artwork.relativePath) {
            identifiers.append(artwork.id)
        }
        return identifiers
    }
}
