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
    /// Non-nil while files are being brought in. The sum of every drop in flight.
    public private(set) var importProgress: ImportProgress?
    /// Drops in flight, oldest first.
    private var running: [(ticket: UUID, progress: ImportProgress)] = []
    /// Called when a release's cover changes, so cached renditions — including the
    /// one on the Lock Screen — can be thrown away.
    public var artworkDidChange: ((UUID) -> Void)?

    public init(context: ModelContext, mediaStore: MediaStore, inspector: any AudioFileInspecting) {
        self.context = context
        self.mediaStore = mediaStore
        self.ingestor = MediaIngestor(store: mediaStore, inspector: inspector)
    }

    // MARK: - Reading

    public func releases() -> [Release] {
        fetch(FetchDescriptor<Release>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }

    /// Most recently played first, resolved in the fetch rather than in memory.
    public func recentlyPlayedReleases(limit: Int = 12) -> [Release] {
        var descriptor = FetchDescriptor<Release>(
            predicate: #Predicate { $0.lastPlayedAt != nil },
            sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return fetch(descriptor)
    }

    public func recentlyPlayed(limit: Int = 12) -> [Release] {
        recentlyPlayedReleases(limit: limit)
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
        // Work out what to remove and what path it lives at, delete the rows, save,
        // and only then touch the disk. Removing bytes first and then failing to
        // save leaves a row pointing at nothing.
        var doomed: [(id: UUID, path: String)] = []
        for track in release.orderedTracks {
            doomed.append(contentsOf: mediaToRemove(for: track))
        }
        if let artwork = release.artwork { doomed.append((artwork.id, artwork.relativePath)) }
        if let motion = release.animatedArtwork { doomed.append((motion.id, motion.relativePath)) }

        context.delete(release)
        guard commit() else { return [] }
        removeFiles(doomed)
        return doomed.map(\.id)
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
        let doomed = mediaToRemove(for: track)
        context.delete(track)
        release?.normalizeOrder()
        guard commit() else { return [] }
        removeFiles(doomed)
        return doomed.map(\.id)
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
        track.release?.refreshDuration()
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
        var doomed: [(id: UUID, path: String)] = []
        if let asset = version.audioAsset {
            let sharedElsewhere = (asset.versions ?? []).contains { $0.id != version.id }
            if !sharedElsewhere {
                doomed.append((asset.id, asset.relativePath))
            }
        }
        context.delete(version)
        if wasCurrent {
            let remaining = (track.versions ?? []).filter { $0.id != version.id }
            let next = remaining.sorted { $0.versionNumber > $1.versionNumber }.first
            track.currentVersionID = next?.id
            track.duration = next?.audioAsset?.duration ?? 0
        }
        track.updatedAt = Date()
        if commit() {
            removeFiles(doomed)
        }
    }

    // MARK: - Media cleanup

    /// The files a track owns outright.
    ///
    /// An asset another version still points at is left alone: the same master can
    /// sit on a single and on the album, and deleting one record must not silence
    /// the other.
    private func mediaToRemove(for track: Track) -> [(id: UUID, path: String)] {
        var doomed: [(id: UUID, path: String)] = []
        let ownVersionIDs = Set((track.versions ?? []).map(\.id))
        for version in track.versions ?? [] {
            guard let asset = version.audioAsset else { continue }
            let sharedElsewhere = (asset.versions ?? []).contains { !ownVersionIDs.contains($0.id) }
            if sharedElsewhere {
                Log.media.info("Keeping shared media still used by another release")
                continue
            }
            doomed.append((asset.id, asset.relativePath))
        }
        if let canvas = track.canvas {
            doomed.append((canvas.id, canvas.relativePath))
        }
        return doomed
    }

    private func removeFiles(_ doomed: [(id: UUID, path: String)]) {
        let paths = doomed.map(\.path)
        Task { [ingestor] in
            for path in paths {
                await ingestor.removeMedia(atRelativePath: path)
            }
        }
    }

    /// Saves, and says whether it worked.
    @discardableResult
    private func commit() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            Log.library.error("Save failed: \(String(describing: error))")
            lastError = DubplateError(.unknown, underlying: error)
            return false
        }
    }

    // MARK: - Saving

    public func save() {
        commit()
    }

    /// Registers a drop that is starting, and hands back its ticket.
    ///
    /// Two drops can be in flight at once — a producer drags a bounce folder in and
    /// then remembers the cover — and a single slot meant the first one to finish
    /// hid the second one's progress, leaving a window that looked idle while it
    /// was still copying gigabytes.
    func beginImport(total: Int) -> UUID {
        let ticket = UUID()
        running.append((ticket, ImportProgress(completed: 0, total: total)))
        publishImportProgress()
        return ticket
    }

    func updateImport(_ ticket: UUID, _ progress: ImportProgress) {
        guard let index = running.firstIndex(where: { $0.ticket == ticket }) else { return }
        running[index].progress = progress
        publishImportProgress()
    }

    func endImport(_ ticket: UUID) {
        running.removeAll { $0.ticket == ticket }
        publishImportProgress()
    }

    private func publishImportProgress() {
        guard !running.isEmpty else {
            importProgress = nil
            return
        }
        // One bar for everything in flight, named after the oldest drop that is
        // still working — a line can only carry one filename, and the drop that
        // started first is the one someone is waiting on.
        let completed = running.reduce(0) { $0 + $1.progress.completed }
        let total = running.reduce(0) { $0 + $1.progress.total }
        let filename = running.first { $0.progress.completed < $0.progress.total }?
            .progress.currentFilename ?? ""
        importProgress = ImportProgress(completed: completed, total: total, currentFilename: filename)
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
