import Foundation
import SwiftData

/// A record: a single, EP, album, mixtape or open-ended project.
///
/// `trackOrder` — not the relationship — is the authority on sequencing. SwiftData
/// relationships are unordered, and CloudKit has no concept of an ordered to-many,
/// so the sequence is stored as an explicit list of track identifiers. See
/// Documentation/DATA_MODEL.md.
@Model
public final class Release {
    public var id: UUID = UUID()
    public var title: String = ""
    public var artistName: String = ""
    public var releaseTypeRaw: String = ReleaseType.album.rawValue
    public var year: Int?
    public var genre: String?
    public var copyrightText: String?
    public var notes: String?
    public var createdAt: Date = Date.distantPast
    public var updatedAt: Date = Date.distantPast
    public var lastPlayedAt: Date?
    /// When a merge was last tidied up. Separate from `updatedAt` so that repairing
    /// a record does not move it to the top of the library.
    public var repairedAt: Date?

    /// Track identifiers in listening order. May contain identifiers for tracks that
    /// have not synced yet, and may omit tracks that arrived from another device;
    /// `orderedTracks` reconciles both cases without mutating the store.
    public var trackOrder: [String] = []

    /// A Finder folder this release watches for new bounces (macOS only, opt-in).
    public var watchFolderBookmark: Data?

    @Relationship(deleteRule: .cascade, inverse: \Track.release)
    public var tracks: [Track]?

    @Relationship(deleteRule: .nullify, inverse: \ArtworkAsset.coverForRelease)
    public var artwork: ArtworkAsset?

    @Relationship(deleteRule: .nullify, inverse: \ArtworkAsset.motionForRelease)
    public var animatedArtwork: ArtworkAsset?

    public init(
        id: UUID = UUID(),
        title: String = "",
        artistName: String = "",
        releaseType: ReleaseType = .album,
        year: Int? = nil,
        genre: String? = nil,
        copyrightText: String? = nil,
        notes: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.releaseTypeRaw = releaseType.rawValue
        self.year = year
        self.genre = genre
        self.copyrightText = copyrightText
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tracks = []
        self.trackOrder = []
    }

    public var releaseType: ReleaseType {
        get { ReleaseType(rawValue: releaseTypeRaw) ?? .album }
        set { releaseTypeRaw = newValue.rawValue }
    }

    /// Tracks in listening order.
    ///
    /// Anything present in the relationship but absent from `trackOrder` — a track
    /// that arrived from another device mid-edit — is appended in creation order
    /// rather than dropped.
    public var orderedTracks: [Track] {
        let present = tracks ?? []
        var byID: [String: Track] = [:]
        for track in present {
            byID[track.id.uuidString] = track
        }
        var result: [Track] = []
        result.reserveCapacity(present.count)
        for identifier in trackOrder {
            if let track = byID.removeValue(forKey: identifier) {
                result.append(track)
            }
        }
        result.append(contentsOf: byID.values.sorted { $0.createdAt < $1.createdAt })
        return result
    }

    public var trackCount: Int {
        tracks?.count ?? 0
    }

    /// Sum of the durations of the current version of every track.
    ///
    /// Denormalised, because a grid of a hundred covers reaching for this would
    /// fault in every track of every release to draw a subtitle.
    public var cachedDuration: TimeInterval = 0

    public var totalDuration: TimeInterval {
        cachedDuration > 0 ? cachedDuration : (tracks ?? []).reduce(0) { $0 + $1.duration }
    }

    /// "Album · 9 tracks" — the line under a release everywhere in the app.
    public var subtitleLine: String {
        let count = trackCount
        let noun = count == 1 ? "track" : "tracks"
        return "\(releaseType.displayName) · \(count) \(noun)"
    }

    /// Rewrites `trackOrder` from the given sequence and renumbers the tracks.
    public func applyOrder(_ ordered: [Track], at date: Date = Date()) {
        trackOrder = ordered.map(\.id.uuidString)
        var numberByDisc: [Int: Int] = [:]
        for track in ordered {
            let next = (numberByDisc[track.discNumber] ?? 0) + 1
            numberByDisc[track.discNumber] = next
            if track.trackNumber != next {
                track.trackNumber = next
                track.updatedAt = date
            }
        }
        cachedDuration = ordered.reduce(0) { $0 + $1.duration }
        updatedAt = date
    }

    /// Re-adds up the run time after a version change, without reordering anything.
    public func refreshDuration() {
        cachedDuration = orderedTracks.reduce(0) { $0 + $1.duration }
    }

    /// Brings `trackOrder` back in line with the relationship after tracks are
    /// added or removed. Safe to call repeatedly.
    public func normalizeOrder(at date: Date = Date()) {
        applyOrder(orderedTracks, at: date)
    }
}
