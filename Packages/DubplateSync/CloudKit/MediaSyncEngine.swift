import Foundation
import CloudKit
import DubplateCore

/// Keeps every device's *catalogue* of media in step: which files exist, how big
/// they are, what they are called and where they belong.
///
/// It deliberately does not move the bytes. `CKSyncEngine` fetches every change in
/// the zone as soon as it appears, which is exactly right for a few hundred bytes
/// of description and exactly wrong for a forty-minute 96/24 master: a phone would
/// fill up with an entire back catalogue nobody asked it to hold. So the engine
/// syncs descriptions, `MediaTransferService` moves bytes on request, and a track
/// whose description has arrived but whose audio has not is what the interface calls
/// "Available on your Mac".
///
/// Why CloudKit at all: the metadata already syncs through it via SwiftData, so the
/// media travels on the same account, in the same private database, under one set of
/// rules. Nothing here is ever public — no share, no public database, no URL that
/// exists outside the account.
public actor MediaSyncEngine {

    public struct Configuration: Sendable {
        public var containerIdentifier: String
        public var zoneName: String
        /// Where the engine's serialized state lives between launches.
        public var stateURL: URL

        public init(
            containerIdentifier: String = DubplateSchema.cloudContainerIdentifier,
            zoneName: String = "DubplateMedia",
            stateURL: URL
        ) {
            self.containerIdentifier = containerIdentifier
            self.zoneName = zoneName
            self.stateURL = stateURL
        }
    }

    /// Field names on the media record.
    enum Field {
        static let kind = "kind"
        static let relativePath = "relativePath"
        static let originalFilename = "originalFilename"
        static let checksum = "checksum"
        static let fileSize = "fileSize"
    }

    /// The description of a file. Small, and safe to fetch everywhere.
    static let recordType = "DubplateMedia"

    private let configuration: Configuration
    private let container: CKContainer
    private let mediaStore: MediaStore
    private let index: MediaIndex
    private var engine: CKSyncEngine?

    /// Called when bytes for an asset land on this device.
    public var onAssetArrived: (@Sendable (UUID, String) async -> Void)?
    /// Called when an asset's transfer state changes, for the availability badges.
    public var onAvailabilityChanged: (@Sendable (UUID, AvailabilityState) async -> Void)?
    /// Called when the engine finishes a round of work.
    public var onActivityChanged: (@Sendable (Bool) async -> Void)?

    public init(configuration: Configuration, mediaStore: MediaStore, index: MediaIndex) {
        self.configuration = configuration
        self.container = CKContainer(identifier: configuration.containerIdentifier)
        self.mediaStore = mediaStore
        self.index = index
    }

    public func setCallbacks(
        onAssetArrived: (@Sendable (UUID, String) async -> Void)? = nil,
        onAvailabilityChanged: (@Sendable (UUID, AvailabilityState) async -> Void)? = nil,
        onActivityChanged: (@Sendable (Bool) async -> Void)? = nil
    ) {
        self.onAssetArrived = onAssetArrived
        self.onAvailabilityChanged = onAvailabilityChanged
        self.onActivityChanged = onActivityChanged
    }

    // MARK: - Lifecycle

    public func start() async {
        guard engine == nil else { return }
        var engineConfiguration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: loadState(),
            delegate: self
        )
        engineConfiguration.automaticallySync = true
        engine = CKSyncEngine(engineConfiguration)
        Log.sync.info("Media sync engine started")

        // Anything that never finished uploading gets re-queued on every launch.
        let pending = await index.pendingUploads()
        if !pending.isEmpty {
            queueUploads(pending.map(\.assetID))
        }
    }

    public func stop() {
        engine = nil
    }

    /// Throws away the change token and starts again. Used when the account changes,
    /// where the token refers to a database this device can no longer see.
    public func resetState() async {
        engine = nil
        try? FileManager.default.removeItem(at: configuration.stateURL)
        await start()
    }

    /// Adds media to the upload queue. Safe to call for something already queued.
    public func queueUploads(_ assetIDs: [UUID]) {
        guard let engine, !assetIDs.isEmpty else { return }
        let zoneID = CKRecordZone.ID(zoneName: configuration.zoneName)
        let changes = assetIDs.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID)
            )
        }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        engine.state.add(pendingRecordZoneChanges: changes)
    }

    public func queueDeletions(_ assetIDs: [UUID]) {
        guard let engine, !assetIDs.isEmpty else { return }
        let zoneID = CKRecordZone.ID(zoneName: configuration.zoneName)
        engine.state.add(
            pendingRecordZoneChanges: assetIDs.map {
                .deleteRecord(CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID))
            }
        )
    }

    /// Asks CloudKit for anything new right away, rather than waiting for the
    /// engine's own schedule. Used by pull-to-refresh and by "Sync Now".
    public func fetchChangesNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
        } catch {
            Log.sync.error("Fetch failed: \(String(describing: error))")
        }
    }

    public func sendChangesNow() async {
        guard let engine else { return }
        do {
            try await engine.sendChanges()
        } catch {
            Log.sync.error("Send failed: \(String(describing: error))")
        }
    }

    // MARK: - State

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: configuration.stateURL) else { return nil }
        do {
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            // A state file we cannot read means a full re-fetch, which is slow but
            // correct. Never a reason to fail to launch.
            Log.sync.error("Sync state unreadable, resyncing from scratch")
            return nil
        }
    }

    private func save(state: CKSyncEngine.State.Serialization) {
        do {
            try FileManager.default.createDirectory(
                at: configuration.stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(state).write(to: configuration.stateURL, options: .atomic)
        } catch {
            Log.sync.error("Could not save sync state: \(String(describing: error))")
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension MediaSyncEngine: CKSyncEngineDelegate {

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            save(state: update.stateSerialization)

        case .accountChange(let change):
            await handleAccountChange(change)

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                await adopt(record: modification.record)
            }
            for deletion in changes.deletions {
                await forget(recordName: deletion.recordID.recordName)
            }

        case .sentRecordZoneChanges(let sent):
            for saved in sent.savedRecords {
                if let assetID = UUID(uuidString: saved.recordID.recordName) {
                    await index.markUploaded(assetID)
                    await onAvailabilityChanged?(assetID, .available)
                }
            }
            for failure in sent.failedRecordSaves {
                await handle(failure: failure, syncEngine: syncEngine)
            }

        case .fetchedDatabaseChanges(let changes):
            // A zone deleted on another device means everything in it is gone from
            // CloudKit; the local files stay, but they are no longer uploaded.
            if !changes.deletions.isEmpty {
                await index.markEverythingNotUploaded()
                Log.sync.info("A media zone was removed elsewhere; everything is queued to upload again")
            }

        case .willSendChanges, .willFetchChanges:
            await onActivityChanged?(true)

        case .didSendChanges, .didFetchChanges:
            await onActivityChanged?(false)

        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            await self.makeRecord(for: recordID)
        }
    }

    // MARK: - Records

    private func makeRecord(for recordID: CKRecord.ID) async -> CKRecord? {
        guard let assetID = UUID(uuidString: recordID.recordName),
              let descriptor = await index.descriptor(for: assetID)
        else {
            return nil
        }
        guard mediaStore.exists(relativePath: descriptor.relativePath) else {
            // The file has gone from under us. Drop it from the queue rather than
            // failing this batch and every batch after it.
            Log.sync.error("Skipping upload of missing file \(descriptor.originalFilename, privacy: .public)")
            await index.remove(assetID)
            return nil
        }

        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record[Field.kind] = descriptor.kind.rawValue
        record[Field.relativePath] = descriptor.relativePath
        record[Field.originalFilename] = descriptor.originalFilename
        record[Field.checksum] = descriptor.checksum
        record[Field.fileSize] = descriptor.fileSize
        return record
    }

    /// A description arrived from another device. Record it, and say whether the
    /// bytes behind it happen to be here already.
    private func adopt(record: CKRecord) async {
        guard let assetID = UUID(uuidString: record.recordID.recordName),
              let relativePath = record[Field.relativePath] as? String,
              let kindRaw = record[Field.kind] as? String,
              let kind = MediaDescriptor.Kind(rawValue: kindRaw)
        else {
            return
        }

        await index.record(
            MediaDescriptor(
                assetID: assetID,
                kind: kind,
                relativePath: relativePath,
                originalFilename: record[Field.originalFilename] as? String ?? "",
                checksum: record[Field.checksum] as? String ?? "",
                fileSize: record[Field.fileSize] as? Int64 ?? 0,
                isUploaded: true
            )
        )

        if mediaStore.exists(relativePath: relativePath) {
            await onAssetArrived?(assetID, relativePath)
            await onAvailabilityChanged?(assetID, .available)
        } else {
            await onAvailabilityChanged?(assetID, .cloudOnly)
        }
    }

    private func forget(recordName: String) async {
        guard let assetID = UUID(uuidString: recordName) else { return }
        // The record is gone from CloudKit, but the bytes on this device belong to
        // the person. Media is never deleted here — only the library deletes media,
        // and only when the person deletes the thing that owns it.
        await index.remove(assetID)
    }

    private func handle(
        failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine
    ) async {
        guard let assetID = UUID(uuidString: failure.record.recordID.recordName) else { return }
        switch failure.error.code {
        case .serverRecordChanged:
            // Another device described this asset first. Descriptions are immutable
            // once written — the record name is the asset identifier and an asset's
            // contents never change — so the server's copy is already correct.
            await index.markUploaded(assetID)
        case .zoneNotFound, .userDeletedZone:
            let zoneID = CKRecordZone.ID(zoneName: configuration.zoneName)
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited:
            // The engine retries these itself on its own schedule.
            await onAvailabilityChanged?(assetID, .local)
        case .quotaExceeded:
            await onAvailabilityChanged?(assetID, .error)
            Log.sync.error("iCloud storage is full; upload deferred")
        default:
            await onAvailabilityChanged?(assetID, .error)
            Log.sync.error("Upload failed: \(String(describing: failure.error))")
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) async {
        switch change.changeType {
        case .signIn:
            let pending = await index.all().map(\.assetID)
            queueUploads(pending)
        case .signOut, .switchAccounts:
            // Local media stays exactly where it is — Dubplate never removes a
            // person's audio because an account changed — but nothing on this device
            // can be assumed to be in the new account any more.
            Log.sync.info("iCloud account changed; local library untouched, upload state cleared")
            await index.markEverythingNotUploaded()
        @unknown default:
            break
        }
    }
}
