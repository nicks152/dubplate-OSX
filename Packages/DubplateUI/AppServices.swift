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
        await sync.start()
        analyser.analysePending()
    }

    public func dismissStartupNotice() {
        startupNotice = nil
    }

    // MARK: - Playback helpers

    /// Plays a whole release from the top.
    public func play(release: Release, startingAt track: Track? = nil, shuffled: Bool = false) {
        LibraryRepair.repair(release, in: container.mainContext)
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

    /// Plays a specific version of the track that is already playing, keeping the
    /// position, so two mixes can be compared at the same moment.
    public func audition(version: TrackVersion, of track: Track) {
        guard let item = QueueBuilder.item(for: track, version: version) else { return }
        if player.currentItem?.trackID == track.id {
            player.switchToVersion(item)
        } else {
            player.play(item)
        }
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

    /// Brings every current version of a release onto this device.
    public func download(release: Release) async {
        let assets = release.orderedTracks.compactMap(\.currentAsset)
        var ids = assets.map(\.id)
        if let artworkAsset = release.artwork { ids.append(artworkAsset.id) }
        for asset in assets where asset.availability == .cloudOnly {
            asset.availability = .downloading
        }
        try? container.mainContext.save()
        await sync.download(assetIDs: ids)
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
