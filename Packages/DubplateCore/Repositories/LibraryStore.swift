import Foundation
import SwiftData
import Observation

/// The library, and everything that can be done to it.
///
/// One object rather than a repository per entity: the operations people actually
/// perform — make a release, drop bounces on it, reorder it, swap a version —
/// touch several entities at once, and splitting them apart would only add
/// indirection. Views observe this; nothing else talks to `ModelContext`.
@MainActor
@Observable
public final class LibraryStore {
    public let context: ModelContext
    public let mediaStore: MediaStore
    public let ingestor: MediaIngestor

    /// The most recent thing that went wrong, for the interface to present once.
    public var lastError: DubplateError?
    /// Non-nil while files are being brought in.
    public private(set) var importProgress: ImportProgress?

    public init(context: ModelContext, mediaStore: MediaStore, inspector: any AudioFileInspecting) {
        self.context = context
        self.mediaStore = mediaStore
        self.ingestor = MediaIngestor(store: mediaStore, inspector: inspector)
    }

    // MARK: - Reading

    public func releases() -> [Release] {
        fetch(FetchDescriptor<Release>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }

    public func releases(ofType type: ReleaseType) -> [Release] {
        releases().filter { $0.releaseType == type }
    }

    public func recentlyPlayed(limit: Int = 12) -> [Release] {
        releases()
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    public func release(id: UUID) -> Release? {
        fetch(FetchDescriptor<Release>(predicate: #Predicate { $0.id == id })).first
    }

    public func track(id: UUID) -> Track? {
        fetch(FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })).first
    }

    /// Tracks that have been imported but not put on a release yet.
    public func inboxTracks() -> [Track] {
        fetch(
            FetchDescriptor<Track>(
                predicate: #Predicate { $0.release == nil },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        )
    }

    public func artistProfile() -> ArtistProfile {
        if let existing = fetch(FetchDescriptor<ArtistProfile>()).first {
            return existing
        }
        let profile = ArtistProfile(displayName: "", defaultArtistName: "")
        context.insert(profile)
        save()
        return profile
    }

    public var defaultArtistName: String {
        let profile = artistProfile()
        if !profile.defaultArtistName.isEmpty { return profile.defaultArtistName }
        return releases().first?.artistName ?? ""
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            Log.library.error("Fetch failed: \(String(describing: error))")
            lastError = DubplateError(.unknown, underlying: error)
            return []
        }
    }

    // MARK: - Releases

    @discardableResult
    public func createRelease(
        title: String,
        artistName: String,
        type: ReleaseType,
        year: Int? = nil
    ) -> Release {
        let release = Release(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            artistName: artistName.trimmingCharacters(in: .whitespacesAndNewlines),
            releaseType: type,
            year: year ?? Calendar.current.component(.year, from: Date())
        )
        context.insert(release)
        save()
        Log.library.info("Created release \(release.title, privacy: .public)")
        return release
    }

    public func update(
        release: Release,
        title: String? = nil,
        artistName: String? = nil,
        type: ReleaseType? = nil,
        year: Int?? = nil,
        genre: String?? = nil,
        copyrightText: String?? = nil,
        notes: String?? = nil
    ) {
        if let title { release.title = title }
        if let artistName { release.artistName = artistName }
        if let type { release.releaseType = type }
        if let year { release.year = year }
        if let genre { release.genre = genre }
        if let copyrightText { release.copyrightText = copyrightText }
        if let notes { release.notes = notes }
        release.updatedAt = Date()
        save()
    }

    /// Deletes a release and returns the assets that went with it, so the caller
    /// can clear the same bytes out of iCloud. Without that, deleting a record
    /// leaves every master in the private database indefinitely — the person cannot
    /// get their own unreleased music out of iCloud from inside the application.
    @discardableResult
    public func delete(release: Release) -> [UUID] {
        var removed: [UUID] = []
        for track in release.orderedTracks {
            removed.append(contentsOf: deleteMedia(for: track))
        }
        if let artwork = release.artwork, deleteMedia(for: artwork) {
            removed.append(artwork.id)
        }
        if let motion = release.animatedArtwork, deleteMedia(for: motion) {
            removed.append(motion.id)
        }
        context.delete(release)
        save()
        return removed
    }

    public func markPlayed(release: Release, at date: Date = Date()) {
        release.lastPlayedAt = date
        save()
    }

    // MARK: - Ordering

    public func move(in release: Release, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var ordered = release.orderedTracks
        ordered.move(fromOffsets: offsets, toOffset: destination)
        release.applyOrder(ordered)
        save()
    }

    public func setOrder(_ tracks: [Track], in release: Release) {
        release.applyOrder(tracks)
        save()
    }

    // MARK: - Tracks

    @discardableResult
    public func delete(track: Track) -> [UUID] {
        let release = track.release
        let removed = deleteMedia(for: track)
        context.delete(track)
        release?.normalizeOrder()
        save()
        return removed
    }

    /// Takes a track off a record without destroying anything: it goes back to the
    /// Inbox, with every mix intact. This is what "remove from release" should mean.
    public func removeFromRelease(track: Track) {
        let release = track.release
        release?.trackOrder.removeAll { $0 == track.id.uuidString }
        track.release = nil
        track.updatedAt = Date()
        release?.normalizeOrder()
        save()
    }

    public func move(track: Track, to release: Release) {
        track.release?.trackOrder.removeAll { $0 == track.id.uuidString }
        track.release = release
        release.trackOrder.append(track.id.uuidString)
        release.normalizeOrder()
        track.updatedAt = Date()
        save()
    }

    public func update(
        track: Track,
        title: String? = nil,
        artistName: String? = nil,
        featuredArtists: String?? = nil,
        discNumber: Int? = nil,
        explicitFlag: Bool? = nil,
        notes: String?? = nil
    ) {
        if let title { track.title = title }
        if let artistName { track.artistName = artistName }
        if let featuredArtists { track.featuredArtists = featuredArtists }
        if let discNumber { track.discNumber = discNumber }
        if let explicitFlag { track.explicitFlag = explicitFlag }
        if let notes { track.notes = notes }
        track.updatedAt = Date()
        track.release?.updatedAt = track.updatedAt
        save()
    }

    // MARK: - Versions

    public func makeCurrent(version: TrackVersion, of track: Track) {
        track.makeCurrent(version)
        track.release?.updatedAt = Date()
        save()
        Log.library.info("Current version of \(track.displayTitle, privacy: .public) is now \(version.shortName, privacy: .public)")
    }

    public func rename(version: TrackVersion, to label: String) {
        version.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        version.track?.updatedAt = Date()
        save()
    }

    public func annotate(version: TrackVersion, notes: String) {
        version.notes = notes
        save()
    }

    /// Deleting the current version promotes the newest remaining one, so a track
    /// is never left pointing at nothing.
    public func delete(version: TrackVersion) {
        guard let track = version.track else {
            context.delete(version)
            save()
            return
        }
        let wasCurrent = track.currentVersionID == version.id
        if let asset = version.audioAsset {
            deleteMedia(for: asset, excluding: version)
        }
        context.delete(version)
        if wasCurrent {
            let remaining = (track.versions ?? []).filter { $0.id != version.id }
            let next = remaining.sorted { $0.versionNumber > $1.versionNumber }.first
            track.currentVersionID = next?.id
            track.duration = next?.audioAsset?.duration ?? 0
        }
        track.updatedAt = Date()
        save()
    }

    // MARK: - Media cleanup

    @discardableResult
    private func deleteMedia(for track: Track) -> [UUID] {
        var removed: [UUID] = []
        for version in track.versions ?? [] {
            if let asset = version.audioAsset, deleteMedia(for: asset, excluding: version) {
                removed.append(asset.id)
            }
        }
        if let canvas = track.canvas, deleteMedia(for: canvas) {
            removed.append(canvas.id)
        }
        return removed
    }

    /// Removes the file behind an asset — unless another version still points at it.
    /// The same master can appear on a single and on the album; deleting one record
    /// must not silence the other.
    @discardableResult
    private func deleteMedia(for asset: AudioAsset, excluding version: TrackVersion?) -> Bool {
        let versionID = version?.id
        let othersRemain = (asset.versions ?? []).contains { $0.id != versionID }
        guard !othersRemain else {
            Log.media.info("Keeping shared media still used by another version")
            return false
        }
        let path = asset.relativePath
        Task { await ingestor.removeMedia(atRelativePath: path) }
        return true
    }

    @discardableResult
    private func deleteMedia(for asset: ArtworkAsset) -> Bool {
        let path = asset.relativePath
        Task { await ingestor.removeMedia(atRelativePath: path) }
        return true
    }

    // MARK: - Saving

    public func save() {
        do {
            try context.save()
        } catch {
            Log.library.error("Save failed: \(String(describing: error))")
            lastError = DubplateError(.unknown, underlying: error)
        }
    }

    func setImportProgress(_ progress: ImportProgress?) {
        importProgress = progress
    }
}

/// How far along a drop is.
public struct ImportProgress: Equatable, Sendable {
    public var completed: Int
    public var total: Int
    public var currentFilename: String

    public init(completed: Int = 0, total: Int = 0, currentFilename: String = "") {
        self.completed = completed
        self.total = total
        self.currentFilename = currentFilename
    }

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    public var isFinished: Bool { completed >= total }
}
