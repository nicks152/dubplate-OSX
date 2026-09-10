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

    public init(
        container: ModelContainer,
        mediaStore: MediaStore,
        settings: DubplateSettings,
        startupNotice: DubplateError? = nil
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

        player.didStartRelease = { [weak self] releaseID in
            guard let self, let release = library.release(id: releaseID) else { return }
            library.markPlayed(release: release)
        }
        player.needsDownload = { [weak self] item in
            guard let self else { return }
            Task { await fetchAndResume(item) }
        }
        library.artworkDidChange = { [weak self] _ in
            guard let self else { return }
            artwork.invalidateAll()
            player.invalidateArtwork()
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
            player.resumeAfterDownload()
        } else if player.awaitingDownloadOf?.id == item.id {
            player.abandonPendingItem()
        }
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
        return AppServices(container: container, mediaStore: store, settings: settings)
    }

    // MARK: - Startup

    public func start() async {
        // What is actually on this device is not stored and not synced, so it has to
        // be established by looking — once, at launch, before anything asks.
        MediaAvailability.refreshAll(in: container.mainContext, using: mediaStore)
        NetworkPath.start()
        await sync.start()
        analyser.analysePending()
    }

    public func dismissStartupNotice() {
        startupNotice = nil
    }

    // MARK: - Playback helpers

    /// Plays a whole release from the top.
    public func play(release: Release, startingAt track: Track? = nil, shuffled: Bool = false) {
        open(release: release)
        let items = QueueBuilder.items(for: release)
        guard !items.isEmpty else { return }
        let index = track.flatMap { target in items.firstIndex { $0.trackID == target.id } } ?? 0
        player.play(items, startingAt: index, shuffled: shuffled)
    }

    /// Plays one loose track from the inbox.
    public func play(track: Track) {
        guard let item = QueueBuilder.item(for: track) else { return }
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
        let summary = outcome.summary(trackTitle: trackTitle)
        guard !summary.isEmpty, summary != "Nothing to add" || !outcome.failures.isEmpty else {
            lastImportSummary = outcome.isEmpty ? "Nothing new in that drop" : summary
            return
        }
        lastImportSummary = summary
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
    }

    /// Deletes a release and clears the same bytes out of iCloud.
    public func delete(release: Release) {
        let removed = library.delete(release: release)
        artwork.invalidateAll()
        guard !removed.isEmpty else { return }
        Task { await sync.forget(assetIDs: removed) }
    }

    /// Deletes one track and everything under it, clearing iCloud too.
    public func delete(track: Track) {
        let removed = library.delete(track: track)
        guard !removed.isEmpty else { return }
        Task { await sync.forget(assetIDs: removed) }
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

    /// Opens a release: repairs it after any merge, works out what is actually here,
    /// and — on a device that is not the one the record was made on — starts
    /// fetching what is missing without being asked.
    ///
    /// This is what "I made it on the Mac and it was on my phone" has to mean.
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
