import Foundation
import Observation
import SwiftData
import DubplateCore

/// What the interface is allowed to say about syncing.
///
/// Six states, and most of the time the answer is `.synced`, which the interface
/// shows by saying nothing at all. Dubplate does not decorate every row with a
/// cloud.
public enum SyncStatus: String, Sendable {
    case synced
    case syncing
    case waiting
    case availableOnOtherDevice
    case downloading
    case offline

    public var label: String {
        switch self {
        case .synced: return "Synced"
        case .syncing: return "Syncing"
        case .waiting: return "Waiting"
        case .availableOnOtherDevice: return "Available on your Mac"
        case .downloading: return "Downloading"
        case .offline: return "Offline"
        }
    }

    /// Whether it is worth showing at all.
    public var isWorthMentioning: Bool {
        self != .synced
    }
}

/// The one object the applications talk to about syncing.
///
/// It owns the account check, the media transfer engine and the post-merge repair,
/// and it exposes a state small enough to put in a corner of a window.
@MainActor
@Observable
public final class SyncCoordinator {
    public private(set) var status: SyncStatus = .synced
    public private(set) var accountState: CloudAccountState = .unknown
    public private(set) var lastSyncedAt: Date?
    public private(set) var isEnabled: Bool

    private let account = CloudAccount()
    private let engine: MediaSyncEngine
    private let index: MediaIndex
    private let context: ModelContext
    private let mediaStore: MediaStore
    private var accountTask: Task<Void, Never>?
    private var isTransferring = false

    public init(context: ModelContext, mediaStore: MediaStore, isEnabled: Bool = true) {
        self.context = context
        self.mediaStore = mediaStore
        self.isEnabled = isEnabled

        let supportDirectory = mediaStore.root.deletingLastPathComponent()
        self.index = MediaIndex(directory: supportDirectory)
        self.engine = MediaSyncEngine(
            configuration: .init(
                stateURL: supportDirectory.appending(path: "sync-state.json", directoryHint: .notDirectory)
            ),
            mediaStore: mediaStore,
            index: index
        )
    }

    // MARK: - Lifecycle

    public func start() async {
        accountState = await account.state()
        guard isEnabled, accountState.canSync else {
            status = accountState.canSync ? .synced : .offline
            return
        }

        let onArrived: @Sendable (UUID, String) async -> Void = { [weak self] assetID, _ in
            await self?.assetArrived(assetID)
        }
        let onAvailability: @Sendable (UUID, AvailabilityState) async -> Void = { [weak self] assetID, state in
            await self?.setAvailability(state, for: assetID)
        }
        let onActivity: @Sendable (Bool) async -> Void = { [weak self] active in
            await self?.setTransferring(active)
        }
        await engine.setCallbacks(
            onAssetArrived: onArrived,
            onAvailabilityChanged: onAvailability,
            onActivityChanged: onActivity
        )
        await engine.start()
        await backfillIndex()
        watchAccountChanges()
        status = .synced
    }

    public func stop() {
        accountTask?.cancel()
        accountTask = nil
        Task { await engine.stop() }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            Task { await start() }
        } else {
            stop()
            status = .offline
        }
    }

    /// "Sync Now".
    public func syncNow() async {
        guard isEnabled, accountState.canSync else { return }
        status = .syncing
        await engine.sendChangesNow()
        await engine.fetchChangesNow()
        lastSyncedAt = Date()
        status = .synced
    }

    // MARK: - Registering media

    /// Called after an import so the new bytes go up.
    public func register(audioAssets: [AudioAsset]) async {
        let descriptors = audioAssets.map {
            MediaDescriptor(
                assetID: $0.id,
                kind: .audio,
                relativePath: $0.relativePath,
                originalFilename: $0.originalFilename,
                checksum: $0.checksum,
                fileSize: $0.fileSize
            )
        }
        await index.record(descriptors)
        guard isEnabled, accountState.canSync else { return }
        await engine.queueUploads(descriptors.map(\.assetID))
    }

    public func register(artworkAssets: [ArtworkAsset]) async {
        let descriptors = artworkAssets.map {
            MediaDescriptor(
                assetID: $0.id,
                kind: .artwork,
                relativePath: $0.relativePath,
                originalFilename: $0.originalFilename,
                checksum: $0.checksum,
                fileSize: $0.fileSize
            )
        }
        await index.record(descriptors)
        guard isEnabled, accountState.canSync else { return }
        await engine.queueUploads(descriptors.map(\.assetID))
    }

    public func forget(assetIDs: [UUID]) async {
        await engine.queueDeletions(assetIDs)
        for assetID in assetIDs {
            await index.remove(assetID)
        }
    }

    /// Rebuilds the transfer index from the library — used on first launch after an
    /// update, and any time the index has been lost.
    private func backfillIndex() async {
        let known = Set(await index.all().map(\.assetID))
        let audio = (try? context.fetch(FetchDescriptor<AudioAsset>())) ?? []
        let artwork = (try? context.fetch(FetchDescriptor<ArtworkAsset>())) ?? []

        let missingAudio = audio.filter { !known.contains($0.id) && !$0.relativePath.isEmpty }
        let missingArtwork = artwork.filter { !known.contains($0.id) && !$0.relativePath.isEmpty }
        guard !missingAudio.isEmpty || !missingArtwork.isEmpty else { return }

        await register(audioAssets: missingAudio)
        await register(artworkAssets: missingArtwork)
        Log.sync.info("Backfilled \(missingAudio.count + missingArtwork.count) assets into the media index")
    }

    // MARK: - Reacting

    private func assetArrived(_ assetID: UUID) {
        guard let asset = fetchAudioAsset(assetID) else { return }
        asset.availability = .available
        save()
        // A version that has just become playable can change what a track should
        // be pointing at, so repair the release it belongs to.
        if let release = owningRelease(ofAssetWithID: assetID) {
            LibraryRepair.repair(release, in: context)
        }
    }

    private func setAvailability(_ state: AvailabilityState, for assetID: UUID) {
        if let audio = fetchAudioAsset(assetID) {
            audio.availability = state
        } else if let artwork = fetchArtworkAsset(assetID) {
            artwork.availability = state
        }
        save()
    }

    private func setTransferring(_ active: Bool) {
        isTransferring = active
        status = active ? .syncing : .synced
        if !active { lastSyncedAt = Date() }
    }

    private func watchAccountChanges() {
        accountTask?.cancel()
        accountTask = Task { [weak self] in
            for await _ in CloudAccount.accountChanges {
                guard let self else { return }
                accountState = await account.state()
                status = accountState.canSync ? .synced : .offline
            }
        }
    }

    private func owningRelease(ofAssetWithID id: UUID) -> Release? {
        let descriptor = FetchDescriptor<TrackVersion>(
            predicate: #Predicate { $0.audioAsset?.id == id }
        )
        return (try? context.fetch(descriptor).first)?.track?.release
    }

    private func fetchAudioAsset(_ id: UUID) -> AudioAsset? {
        try? context.fetch(FetchDescriptor<AudioAsset>(predicate: #Predicate { $0.id == id })).first
    }

    private func fetchArtworkAsset(_ id: UUID) -> ArtworkAsset? {
        try? context.fetch(FetchDescriptor<ArtworkAsset>(predicate: #Predicate { $0.id == id })).first
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.sync.error("Could not record sync change: \(String(describing: error))")
        }
    }
}
