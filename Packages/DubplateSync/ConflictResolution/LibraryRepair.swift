import Foundation
import SwiftData
import DubplateCore

/// Puts a release back in order after a sync.
///
/// SwiftData's CloudKit mirroring merges property by property, which is right for
/// titles and wrong for anything with structure. This runs when a release is opened
/// and after a sync settles: it is idempotent, it never deletes anything, and it
/// never touches a release that is already consistent (so it does not generate
/// pointless writes that would sync back out again).
public enum LibraryRepair {

    @discardableResult
    public static func repair(_ release: Release, in context: ModelContext) -> Bool {
        var changed = false
        let tracks = release.tracks ?? []
        let present = tracks.map(\.id.uuidString)
        let creationOrder = tracks
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.id.uuidString)

        if TrackOrderMerge.needsReconciling(order: release.trackOrder, present: present) {
            release.trackOrder = TrackOrderMerge.reconcile(
                order: release.trackOrder,
                present: present,
                creationOrder: creationOrder
            )
            changed = true
        }

        for (index, track) in release.orderedTracks.enumerated() where track.trackNumber != index + 1 {
            track.trackNumber = index + 1
            changed = true
        }

        for track in tracks where repair(track) {
            changed = true
        }

        if changed {
            release.updatedAt = Date()
            do {
                try context.save()
            } catch {
                Log.sync.error("Could not save repaired release: \(String(describing: error))")
            }
            Log.sync.info("Repaired release \(release.title, privacy: .public) after merge")
        }
        return changed
    }

    @discardableResult
    static func repair(_ track: Track) -> Bool {
        var changed = false
        let versions = track.versions ?? []
        guard !versions.isEmpty else {
            if track.currentVersionID != nil {
                track.currentVersionID = nil
                changed = true
            }
            return changed
        }

        let entries = versions.map {
            VersionNumbering.Entry(id: $0.id, number: $0.versionNumber, createdAt: $0.createdAt)
        }
        let reassignments = VersionNumbering.resolveCollisions(entries)
        for version in versions {
            if let number = reassignments[version.id], version.versionNumber != number {
                version.versionNumber = number
                changed = true
            }
        }

        // A version deleted elsewhere must not leave the track unplayable.
        if track.currentVersionID == nil || !versions.contains(where: { $0.id == track.currentVersionID }) {
            let newest = versions.sorted { $0.versionNumber > $1.versionNumber }.first
            track.currentVersionID = newest?.id
            changed = true
        }

        if let duration = track.currentVersion?.audioAsset?.duration, track.duration != duration {
            track.duration = duration
            changed = true
        }

        if changed {
            track.updatedAt = Date()
        }
        return changed
    }
}
