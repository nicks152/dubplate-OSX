import Foundation
import SwiftData

/// A song on a record.
///
/// A track is not tied to one audio file: it owns a list of `TrackVersion`s and
/// points at whichever one is current. `currentVersionID` is the single authority
/// for that choice — there is no `isCurrent` flag to fall out of step with it.
@Model
public final class Track {
    public var id: UUID = UUID()
    public var title: String = ""
    public var artistName: String = ""
    public var featuredArtists: String?
    public var trackNumber: Int = 1
    public var discNumber: Int = 1
    public var explicitFlag: Bool = false
    public var notes: String?
    public var currentVersionID: UUID?
    /// Duration of the current version, denormalised so that lists never touch disk.
    public var duration: TimeInterval = 0
    public var createdAt: Date = Date.distantPast
    public var updatedAt: Date = Date.distantPast

    public var release: Release?

    @Relationship(deleteRule: .cascade, inverse: \TrackVersion.track)
    public var versions: [TrackVersion]?

    @Relationship(deleteRule: .nullify, inverse: \ArtworkAsset.canvasForTrack)
    public var canvas: ArtworkAsset?

    public init(
        id: UUID = UUID(),
        title: String = "",
        artistName: String = "",
        featuredArtists: String? = nil,
        trackNumber: Int = 1,
        discNumber: Int = 1,
        explicitFlag: Bool = false,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.featuredArtists = featuredArtists
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.explicitFlag = explicitFlag
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.versions = []
    }

    /// Versions newest first — the order the version list is always shown in.
    public var orderedVersions: [TrackVersion] {
        (versions ?? []).sorted { lhs, rhs in
            if lhs.versionNumber != rhs.versionNumber {
                return lhs.versionNumber > rhs.versionNumber
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    public var currentVersion: TrackVersion? {
        let all = versions ?? []
        if let identifier = currentVersionID,
           let match = all.first(where: { $0.id == identifier }) {
            return match
        }
        // Self-healing: a version deleted on another device must not leave the
        // track unplayable. Fall back to the newest version we do have.
        return orderedVersions.first
    }

    public var currentAsset: AudioAsset? {
        currentVersion?.audioAsset
    }

    public var versionCount: Int {
        versions?.count ?? 0
    }

    /// The next version number to hand out. Monotonic, never reuses a number even
    /// after deletions, so version labels stay stable in conversation.
    public var nextVersionNumber: Int {
        ((versions ?? []).map(\.versionNumber).max() ?? 0) + 1
    }

    /// Display name shown when a track has no title yet.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return currentVersion?.audioAsset?.originalFilename ?? "Untitled"
    }

    /// "feat." line, or `nil` when there are no features.
    public var featureLine: String? {
        guard let featured = featuredArtists?.trimmingCharacters(in: .whitespacesAndNewlines),
              !featured.isEmpty else { return nil }
        return "feat. \(featured)"
    }

    public var availability: AvailabilityState {
        currentAsset?.availability ?? .missing
    }

    /// Makes `version` current and re-denormalises duration.
    public func makeCurrent(_ version: TrackVersion, at date: Date = Date()) {
        currentVersionID = version.id
        duration = version.audioAsset?.duration ?? duration
        updatedAt = date
    }
}
