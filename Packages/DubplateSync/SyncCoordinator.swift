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

    /// Files currently moving in either direction.
    public private(set) var transfers: [MediaTransferService.Transfer] = []

    private let account = CloudAccount()
    private let engine: MediaSyncEngine
    private let transferService: MediaTransferService
    private let index: MediaIndex
    private let context: ModelContext
    private let mediaStore: MediaStore
    private var accountTask: Task<Void, Never>?
    private var backfillTask: Task<Void, Never>?
    /// The last thing that went wrong, for the interface to say once.
    public var lastError: DubplateError?
    /// Availability changes arriving from CloudKit, applied in batches rather than
    /// one fetch-and-save per record.
    private var pendingAvailability: [UUID: AvailabilityState] = [:]
    private var availabilityFlush: Task<Void, Never>?

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
        self.transferService = MediaTransferService(mediaStore: mediaStore, index: index)
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
        await transferService.setCallbacks(
            onProgress: { [weak self] active in
                await self?.setTransfers(active)
            },
            onAvailabilityChanged: onAvailability
        )
        await transferService.setErrorHandler { [weak self] error in
            await self?.report(error)
        }
        watchAccountChanges()
        status = .synced

        // Not awaited: on a device restored from backup this is gigabytes of
        // upload, and nothing else — playback, analysis, the whole interface —
        // should wait behind it.
        backfillTask = Task { [weak self] in
            await self?.backfillIndex()
        }
    }

    public func stop() {
        accountTask?.cancel()
        accountTask = nil
        backfillTask?.cancel()
        backfillTask = nil
        availabilityFlush?.cancel()
        availabilityFlush = nil
        Task {
            await engine.stop()
            await index.flush()
        }
    }

    public func clearError() {
        lastError = nil
    }

    private func report(_ error: DubplateError) {
        Log.sync.error("Sync error: \(error.title, privacy: .public)")
        lastError = error
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
        await uploadAnythingOutstanding()
        lastSyncedAt = Date()
        status = .synced
    }

    /// Whether a download should be started right now.
    ///
    /// Cellular is a real constraint, not a preference: a 96/24 album is a gigabyte,
    /// and a producer who turned the switch off meant it.
    public func canDownloadNow(allowsCellular: Bool) -> Bool {
        guard isEnabled, accountState.canSync else { return false }
        return allowsCellular || !NetworkPath.isConstrainedOrExpensive
    }

    // MARK: - Moving bytes

    /// Puts the bytes for these assets on this device.
    public func download(assetIDs: [UUID]) async {
        guard isEnabled, accountState.canSync, !assetIDs.isEmpty else { return }
        status = .downloading
        await transferService.clearCancellations()
        await transferService.download(assetIDs)
        status = .synced
    }

    /// Frees the space these assets take on this device. The iCloud copy is
    /// untouched, and anything that has not been uploaded yet is refused.
    public func removeDownloads(assetIDs: [UUID]) async {
        await transferService.removeLocalCopies(assetIDs)
    }

    public func cancelTransfers(assetIDs: [UUID]) async {
        await transferService.cancel(assetIDs)
    }

    /// Uploads anything this device has that iCloud does not.
    private func uploadAnythingOutstanding() async {
        let pending = await index.pendingUploads()
        guard !pending.isEmpty else { return }
        await transferService.upload(pending.map(\.assetID))
    }

    private func setTransfers(_ active: [MediaTransferService.Transfer]) {
        transfers = active
        if !active.isEmpty {
            status = active.contains(where: { !$0.isUpload }) ? .downloading : .syncing
        } else if status == .downloading || status == .syncing {
            status = .synced
        }
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
        let ids = descriptors.map(\.assetID)
        await engine.queueUploads(ids)
        await transferService.upload(ids)
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
        let ids = descriptors.map(\.assetID)
        await engine.queueUploads(ids)
        await transferService.upload(ids)
    }

    /// Called when the person deletes a release: the description and the bytes both
    /// go, on every device.
    public func forget(assetIDs: [UUID]) async {
        await engine.queueDeletions(assetIDs)
        await transferService.deleteRemote(assetIDs)
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

    /// Collects availability changes and applies them together.
    ///
    /// A first sync delivers thousands of records; one fetch and one save each, on
    /// the main actor, is enough to make the interface unusable while it runs.
    private func setAvailability(_ state: AvailabilityState, for assetID: UUID) {
        pendingAvailability[assetID] = state
        guard availabilityFlush == nil else { return }
        availabilityFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.applyPendingAvailability()
        }
    }

    private func applyPendingAvailability() {
        availabilityFlush = nil
        let changes = pendingAvailability
        pendingAvailability.removeAll()
        guard !changes.isEmpty else { return }

        let ids = Set(changes.keys)
        let audio = (try? context.fetch(
            FetchDescriptor<AudioAsset>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for asset in audio {
            if let state = changes[asset.id] { asset.availability = state }
        }
        let artwork = (try? context.fetch(
            FetchDescriptor<ArtworkAsset>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for asset in artwork {
            if let state = changes[asset.id] { asset.availability = state }
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
                let previous = accountState
                accountState = await account.state()
                status = accountState.canSync ? .synced : .offline
                if previous != accountState {
                    await handleAccountChange()
                }
            }
        }
    }

    /// A different iCloud account is a different database.
    ///
    /// The serialized change token belongs to the old account and the index's
    /// "uploaded" flags refer to records the new account cannot see — so keeping
    /// either would leave sync silently dead and, worse, would let "Remove
    /// Download" delete local bytes that exist in no reachable account.
    private func handleAccountChange() async {
        Log.sync.info("iCloud account changed; resetting sync state. No local file is touched.")
        await engine.resetState()
        await index.markEverythingNotUploaded()
        guard accountState.canSync else { return }
        await backfillIndex()
    }

    /// Walks the relationship rather than filtering on an optional-chained
    /// relationship in a `#Predicate`, which SwiftData translates unreliably.
    private func owningRelease(ofAssetWithID id: UUID) -> Release? {
        fetchAudioAsset(id)?.versions?.first?.track?.release
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
