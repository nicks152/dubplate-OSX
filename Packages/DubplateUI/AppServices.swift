import Foundation
import SwiftData
import Observation
import DubplateCore
import DubplateAudio
import DubplateSync

/// Everything the applications share, assembled once at launch.
///
/// Both targets create exactly one of these and put it in the environment. It is
/// not a dependency-injection container and there is no protocol behind it: it is a
/// struct of the four or five objects a music application needs, in one place, so
/// that the two `@main` types stay a dozen lines each.
@MainActor
@Observable
public final class AppServices {
    public let container: ModelContainer
    public let mediaStore: MediaStore
    public let library: LibraryStore
    public let player: PlayerController
    public let artwork: ArtworkLoader
    public let sync: SyncCoordinator
    public let settings: DubplateSettings
    public let analyser: MediaAnalyser

    /// Set when the store had to fall back, so the interface can explain once.
    public private(set) var startupNotice: DubplateError?
    /// One line about what the last drop did, shown briefly and then forgotten.
    public var lastImportSummary: String?
    /// Set when a download was refused because the switch says not on cellular.
    public var downloadBlockedByCellular = false

    /// - Parameter inspectsDisk: whether to establish what is on this device and
    ///   clear up after an interrupted import. False for the sample library, whose
    ///   assets deliberately name files that were never written: looking would
    ///   correctly conclude that none of the demo record is here, and a preview
    ///   whose every track offers to download is not showing anyone anything.
    public init(
        container: ModelContainer,
        mediaStore: MediaStore,
        settings: DubplateSettings,
        startupNotice: DubplateError? = nil,
        inspectsDisk: Bool = true
    ) {
        self.container = container
        self.mediaStore = mediaStore
        self.settings = settings
        self.startupNotice = startupNotice

        let context = container.mainContext
        self.library = LibraryStore(
            context: context,
            mediaStore: mediaStore,
            inspector: AudioFileInspector()
        )
        self.player = PlayerController(mediaStore: mediaStore)
        self.artwork = ArtworkLoader(mediaStore: mediaStore)
        self.sync = SyncCoordinator(
            context: context,
            mediaStore: mediaStore,
            isEnabled: settings.syncEnabled
        )
        self.analyser = MediaAnalyser(context: context, mediaStore: mediaStore, settings: settings)

        // What is actually on this device is not stored and not synced, so it has
        // to be established by looking — and before the first frame, not after it,
        // because an asset nobody has looked at yet answers "not here".
        if inspectsDisk {
            MediaAvailability.refreshAll(in: context, using: mediaStore)
            Self.sweepUnreferencedMedia(in: context, using: mediaStore)
        }

        // `self.` throughout, deliberately. `guard let self` unwraps self for the
        // statements after it, not for the guard's own condition and not for
        // another escaping closure created inside the body — and spelling it out
        // everywhere is cheaper than remembering which of those applies where.
        player.didStartRelease = { [weak self] releaseID in
            guard let self, let release = self.library.release(id: releaseID) else { return }
            self.library.markPlayed(release: release)
        }
        player.needsDownload = { [weak self] item in
            guard let self else { return }
            Task { await self.fetchAndResume(item) }
        }
        library.artworkDidChange = { [weak self] _ in
            guard let self else { return }
            self.artwork.invalidateAll()
            self.player.invalidateArtwork()
        }
    }

    /// Deletes media files no asset refers to.
    ///
    /// An import copies bytes into place before it writes the row, so a force quit
    /// in between leaves a file nothing owns. Only ever called at launch, and only
    /// with identifiers that were actually read: if either fetch fails the sweep is
    /// skipped entirely, because an empty set would mean "delete everything".
    private static func sweepUnreferencedMedia(in context: ModelContext, using store: MediaStore) {
        guard let audio = try? context.fetch(FetchDescriptor<AudioAsset>()),
              let artwork = try? context.fetch(FetchDescriptor<ArtworkAsset>())
        else {
            Log.media.error("Could not read the library; leaving unreferenced media alone")
            return
        }
        let known = Set(audio.map(\.id)).union(artwork.map(\.id))
        let removed = store.removeMedia(notReferencedBy: known)
        if removed > 0 {
            Log.media.info("Removed \(removed) media file(s) left behind by an interrupted import")
        }
    }

    /// Fetches the one file playback is waiting on, then lets it continue.
    private func fetchAndResume(_ item: PlaybackQueueItem) async {
        guard sync.canDownloadNow(allowsCellular: settings.allowsCellularDownloads) else {
            downloadBlockedByCellular = true
            player.abandonPendingItem()
            return
        }
        await sync.download(assetIDs: [item.assetID])
        if let release = library.release(id: item.releaseID) {
            MediaAvailability.refresh(release, using: mediaStore)
        }
        if mediaStore.exists(relativePath: item.relativePath) {
            analyser.reconsiderSkipped()
            player.resumeAfterDownload()
        } else if player.awaitingDownloadOf?.id == item.id {
            player.abandonPendingItem()
        }
    }

    /// Asks for the file playback is holding on, again.
    public func retryPendingDownload() {
        guard let waiting = player.awaitingDownloadOf else { return }
        Task { await self.fetchAndResume(waiting) }
    }

    /// What "Try Again" does for a given failure, or nil when there is nothing the
    /// application could do differently. Nil means no button, which is the whole
    /// point: `retryTitle` and this have to agree, or the copy names a control that
    /// is not there.
    public func retryAction(for error: DubplateError) -> (() -> Void)? {
        switch error.kind {
        case .transferFailed, .iCloudUnavailable:
            return { [weak self] in
                guard let self else { return }
                self.clearErrors()
                // `self.` spelled out inside the nested Task: `guard let self`
                // unwraps it for this closure, not for another escaping closure
                // created inside it.
                Task { await self.sync.syncNow() }
            }
        case .notDownloadedYet:
            return { [weak self] in
                guard let self else { return }
                self.clearErrors()
                self.downloadBlockedByCellular = false
                self.retryPendingDownload()
            }
        default:
            return nil
        }
    }

    /// Clears every channel the banner can be showing, in one place, because both
    /// applications were spelling the same four lines out by hand.
    public func clearErrors() {
        library.lastError = nil
        player.clearError()
        sync.clearError()
        dismissStartupNotice()
    }

    /// The real thing.
    public static func live() -> AppServices {
        let settings = DubplateSettings()
        let (container, notice) = DubplateSchema.containerWithFallback(
            preferring: settings.syncEnabled ? .synced : .localOnly
        )
        let store: MediaStore
        do {
            store = try MediaStore.makeDefault()
            store.removeOrphanedStagingFiles()
        } catch {
            // Without a media directory nothing can be imported, but the library
            // itself is still readable, so carry on and report it.
            Log.media.error("Could not prepare media store: \(String(describing: error))")
            store = MediaStore(root: URL.temporaryDirectory.appending(path: "DubplateMedia"))
        }
        return AppServices(
            container: container,
            mediaStore: store,
            settings: settings,
            startupNotice: notice
        )
    }

    /// Chooses between the real library and a disposable one.
    ///
    /// UI tests must not touch a person's actual records, and a test that depends on
    /// whatever happens to be in the library is a test that fails on someone else's
    /// machine. `--dubplate-ui-testing` gives the tests an in-memory store.
    public static func launchConfigured() -> AppServices {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--dubplate-ui-testing") else { return live() }
        return preview(populated: arguments.contains("--dubplate-sample-library"))
    }

    /// An in-memory library with the three sample records in it, for previews and
    /// for the first launch of a development build.
    public static func preview(populated: Bool = true) -> AppServices {
        let settings = DubplateSettings(defaults: UserDefaults(suiteName: "dubplate.preview") ?? .standard)
        let container = (try? DubplateSchema.container(.ephemeral))
            ?? DubplateSchema.containerWithFallback(preferring: .ephemeral).0
        if populated {
            SampleLibrary.populate(container.mainContext)
        }
        let store = MediaStore(root: URL.temporaryDirectory.appending(path: "DubplatePreview"))
        return AppServices(
            container: container,
            mediaStore: store,
            settings: settings,
            inspectsDisk: false
        )
    }

    // MARK: - Startup

    public func start() async {
        NetworkPath.start()
        await sync.start()
        analyser.analysePending()
    }

    public func dismissStartupNotice() {
        startupNotice = nil
    }

    // MARK: - Playback helpers

    /// Plays a whole release, optionally starting on a particular track.
    public func play(release: Release, startingAt track: Track? = nil, shuffled: Bool = false) {
        open(release: release)
        let items = QueueBuilder.items(for: release)
        guard !items.isEmpty else {
            announce("There is no audio on this release yet")
            return
        }
        var index = 0
        if let track {
            // A track with no playable version is not in the queue. Falling back to
            // the first item answered a double-click on track 8 by playing track 1,
            // which reads as the app ignoring the click.
            guard let found = items.firstIndex(where: { $0.trackID == track.id }) else {
                announce("“\(track.displayTitle)” has no audio to play yet")
                return
            }
            index = found
        }
        player.play(items, startingAt: index, shuffled: shuffled)
    }

    /// Plays one loose track from the inbox.
    public func play(track: Track) {
        guard let item = QueueBuilder.item(for: track) else {
            // Its sibling above says so; a press that does nothing in silence is
            // the failure round 3 wrote its standing test about.
            announce("“\(track.displayTitle)” has no audio to play yet")
            return
        }
        player.play(item)
    }

    /// Plays a specific version, keeping the position where it makes sense.
    ///
    /// Auditioning a mix of track 8 while the album runs must not throw the album
    /// away — which is what replacing the queue with a single item did. If the track
    /// is already in the queue it is swapped in place and jumped to; only a track
    /// that is not part of what is playing starts a new queue.
    public func audition(version: TrackVersion, of track: Track) {
        guard let item = QueueBuilder.item(for: track, version: version) else { return }

        if player.currentItem?.trackID == track.id {
            player.switchToVersion(item)
            return
        }
        if let existing = player.queue.items.first(where: { $0.trackID == track.id }) {
            player.updateQueuedItem(item, replacingID: existing.id)
            player.skip(to: item)
            return
        }
        if let release = track.release {
            play(release: release, startingAt: track)
            player.switchToVersion(item, keepingPosition: false)
            return
        }
        player.play(item)
    }

    /// Reports what a drop actually did. Silence after an import is what makes a
    /// re-dropped bounce indistinguishable from data loss.
    public func report(_ outcome: ImportOutcome, trackTitle: String? = nil) {
        // `summary` always returns something, and a drop that added nothing says
        // so in its own words. The branches that used to be here compared against
        // a copy string duplicated from another file and could never be reached.
        lastImportSummary = outcome.isEmpty && outcome.failures.isEmpty
            ? "Nothing new in that drop"
            : outcome.summary(trackTitle: trackTitle)
    }

    /// One line, said once. Used for the small confirmations that should not be
    /// dialogs.
    public func announce(_ message: String) {
        lastImportSummary = message
    }

    public func clearImportSummary() {
        lastImportSummary = nil
    }

    /// After an import: hand the new files to sync and start measuring them.
    public func registerNewMedia(in release: Release?) async {
        guard let release else {
            analyser.analysePending()
            return
        }
        let assets = release.orderedTracks
            .flatMap { $0.versions ?? [] }
            .compactMap(\.audioAsset)
        await sync.register(audioAssets: assets)
        if let artworkAsset = release.artwork {
            await sync.register(artworkAssets: [artworkAsset])
        }
        analyser.analysePending()
    }

    // MARK: - Offline

    /// Brings a release onto this device.
    ///
    /// Every version, not only the current one: comparing two mixes in the car is
    /// most of why the phone exists, and a previous mix that is still in iCloud
    /// cannot be compared to anything.
    public func download(release: Release, currentVersionsOnly: Bool = false) async {
        guard sync.canDownloadNow(allowsCellular: settings.allowsCellularDownloads) else {
            downloadBlockedByCellular = true
            return
        }
        var assets: [AudioAsset] = []
        for track in release.orderedTracks {
            if currentVersionsOnly {
                if let asset = track.currentAsset { assets.append(asset) }
            } else {
                assets.append(contentsOf: (track.versions ?? []).compactMap(\.audioAsset))
            }
        }
        var ids = assets.map(\.id)
        if let artworkAsset = release.artwork { ids.append(artworkAsset.id) }
        for asset in assets where asset.availability == .cloudOnly {
            asset.transferState = .downloading
        }
        await sync.download(assetIDs: ids)
        MediaAvailability.refresh(release, using: mediaStore)
        // The attempt is over. Anything still claiming to be downloading is not,
        // and leaving the word there is a promise the app is not keeping.
        for asset in assets where asset.transferState == .downloading {
            asset.transferState = nil
        }
    }

    /// Deletes a release and clears the same bytes out of iCloud.
    public func delete(release: Release) {
        let removed = library.delete(release: release)
        artwork.invalidateAll()
        guard !removed.isEmpty else { return }
        Task { await self.sync.forget(assetIDs: removed) }
    }

    /// Deletes one track and everything under it, clearing iCloud too.
    public func delete(track: Track) {
        let removed = library.delete(track: track)
        guard !removed.isEmpty else { return }
        Task { await self.sync.forget(assetIDs: removed) }
    }

    /// A looping visual, with its trim, if the file is actually on this device.
    public func motionSource(for asset: ArtworkAsset) -> MotionSource? {
        guard mediaStore.exists(relativePath: asset.relativePath) else { return nil }
        return MotionSource(
            url: mediaStore.url(forRelativePath: asset.relativePath),
            loopStart: asset.loopStart,
            loopDuration: asset.loopDuration
        )
    }

    /// Total bytes a release would take to hold offline — every mix, since that is
    /// what `download(release:)` fetches.
    public func downloadSize(of release: Release, currentVersionsOnly: Bool = false) -> Int64 {
        release.orderedTracks.reduce(0) { total, track in
            if currentVersionsOnly {
                return total + (track.currentAsset?.fileSize ?? 0)
            }
            return total + (track.versions ?? []).reduce(0) { $0 + ($1.audioAsset?.fileSize ?? 0) }
        }
    }

    /// Opens a release: repairs it after any merge and works out what is actually
    /// on this device.
    ///
    /// Deliberately does *not* start downloading. Browsing ten records on a phone
    /// must not pull ten albums onto it — that is the whole reason the bytes are
    /// separate from the catalogue. Audio arrives when someone presses play, or
    /// when they ask for the record to be held offline.
    public func open(release: Release) {
        guard !release.isDeleted else { return }
        LibraryRepair.repair(release, in: container.mainContext)
        MediaAvailability.refresh(release, using: mediaStore)
    }

    /// Frees the space a release takes on this device, leaving iCloud alone.
    public func removeDownload(for release: Release) async {
        let ids = release.orderedTracks
            .flatMap { $0.versions ?? [] }
            .compactMap(\.audioAsset?.id)
        await sync.removeDownloads(assetIDs: ids)
    }

    /// Keeps the queue in step when the current version of a queued track changes.
    public func refreshQueueEntry(for track: Track) {
        guard let existing = player.queue.items.first(where: { $0.trackID == track.id }),
              let replacement = QueueBuilder.item(for: track)
        else {
            return
        }
        if player.currentItem?.trackID == track.id {
            player.switchToVersion(replacement)
        } else {
            player.updateQueuedItem(replacement, replacingID: existing.id)
        }
    }
}
