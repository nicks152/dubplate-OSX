import Foundation
import CloudKit
import DubplateCore

/// Moves the actual bytes.
///
/// Separate from `MediaSyncEngine` on purpose: descriptions sync everywhere
/// automatically, audio does not. A Mac uploads what it imports; a phone downloads
/// what someone asks it to hold. Each file is one record in the same private
/// database, named by the asset identifier, with the file as a `CKAsset` — so
/// CloudKit does the chunking, the resumption and the integrity checking, and
/// Dubplate does not reimplement any of it.
public actor MediaTransferService {

    /// One file's progress, for the interface.
    public struct Transfer: Sendable, Identifiable {
        public let id: UUID
        public var filename: String
        public var fractionCompleted: Double
        public var isUpload: Bool
    }

    static let recordType = "DubplateMediaFile"
    static let fileField = "file"
    static let assetIDField = "assetID"

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let mediaStore: MediaStore
    private let index: MediaIndex

    private var active: [UUID: Transfer] = [:]
    private var cancelled: Set<UUID> = []

    public var onProgress: (@Sendable ([Transfer]) async -> Void)?
    public var onAvailabilityChanged: (@Sendable (UUID, AvailabilityState) async -> Void)?

    public init(
        containerIdentifier: String = DubplateSchema.cloudContainerIdentifier,
        zoneName: String = "DubplateMedia",
        mediaStore: MediaStore,
        index: MediaIndex
    ) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: zoneName)
        self.mediaStore = mediaStore
        self.index = index
    }

    public func setCallbacks(
        onProgress: (@Sendable ([Transfer]) async -> Void)? = nil,
        onAvailabilityChanged: (@Sendable (UUID, AvailabilityState) async -> Void)? = nil
    ) {
        self.onProgress = onProgress
        self.onAvailabilityChanged = onAvailabilityChanged
    }

    public var transfers: [Transfer] {
        Array(active.values)
    }

    // MARK: - Uploading

    /// Uploads the bytes for assets that are on this device.
    ///
    /// Files go up one at a time rather than in a batch: a batch that fails takes
    /// every file in it down with it, and these files are large enough that
    /// retrying one is much cheaper than retrying eight.
    public func upload(_ assetIDs: [UUID]) async {
        try? await ensureZone()
        for assetID in assetIDs {
            guard !cancelled.contains(assetID) else { continue }
            guard let descriptor = await index.descriptor(for: assetID),
                  mediaStore.exists(relativePath: descriptor.relativePath)
            else { continue }

            let url = mediaStore.url(forRelativePath: descriptor.relativePath)
            let record = CKRecord(
                recordType: Self.recordType,
                recordID: CKRecord.ID(recordName: assetID.uuidString, zoneID: zoneID)
            )
            record[Self.assetIDField] = assetID.uuidString
            record[Self.fileField] = CKAsset(fileURL: url)

            begin(Transfer(id: assetID, filename: descriptor.originalFilename, fractionCompleted: 0, isUpload: true))
            do {
                _ = try await database.modifyRecords(
                    saving: [record],
                    deleting: [],
                    savePolicy: .allKeys
                )
                await index.markUploaded(assetID)
                await onAvailabilityChanged?(assetID, .available)
                Log.sync.info("Uploaded \(descriptor.originalFilename, privacy: .public)")
            } catch let error as CKError where error.code == .serverRecordChanged {
                // Already up there. Assets never change once written, so this is a
                // success, not a conflict.
                await index.markUploaded(assetID)
            } catch {
                Log.sync.error("Upload failed for \(descriptor.originalFilename, privacy: .public): \(String(describing: error))")
                await onAvailabilityChanged?(assetID, .local)
            }
            finish(assetID)
        }
    }

    // MARK: - Downloading

    /// Fetches the bytes for specific assets onto this device.
    public func download(_ assetIDs: [UUID]) async {
        for assetID in assetIDs {
            guard !cancelled.contains(assetID) else { continue }
            guard let descriptor = await index.descriptor(for: assetID) else { continue }
            if mediaStore.exists(relativePath: descriptor.relativePath) {
                await onAvailabilityChanged?(assetID, .available)
                continue
            }

            begin(Transfer(id: assetID, filename: descriptor.originalFilename, fractionCompleted: 0, isUpload: false))
            await onAvailabilityChanged?(assetID, .downloading)

            do {
                let recordID = CKRecord.ID(recordName: assetID.uuidString, zoneID: zoneID)
                let record = try await database.record(for: recordID)
                guard let asset = record[Self.fileField] as? CKAsset, let temporary = asset.fileURL else {
                    await onAvailabilityChanged?(assetID, .missing)
                    finish(assetID)
                    continue
                }
                // CloudKit hands over a temporary file it is about to delete: move
                // it rather than copying, so a 300 MB master is not written twice.
                try mediaStore.adopt(temporaryFile: temporary, asRelativePath: descriptor.relativePath)
                await onAvailabilityChanged?(assetID, .available)
                Log.sync.info("Downloaded \(descriptor.originalFilename, privacy: .public)")
            } catch let error as CKError where error.code == .unknownItem {
                // The description arrived before the bytes were uploaded. Not an
                // error — the other device is still working.
                await onAvailabilityChanged?(assetID, .cloudOnly)
            } catch {
                Log.sync.error("Download failed for \(descriptor.originalFilename, privacy: .public): \(String(describing: error))")
                await onAvailabilityChanged?(assetID, .error)
            }
            finish(assetID)
        }
    }

    /// Deletes local bytes but never the cloud copy. Removing a download must never
    /// be able to lose a mix.
    public func removeLocalCopies(_ assetIDs: [UUID]) async {
        for assetID in assetIDs {
            guard let descriptor = await index.descriptor(for: assetID), descriptor.isUploaded else {
                // Never delete the only copy of something that is not in iCloud.
                Log.sync.info("Refusing to remove a local file that has not been uploaded")
                continue
            }
            try? mediaStore.remove(relativePath: descriptor.relativePath)
            await onAvailabilityChanged?(assetID, .cloudOnly)
        }
    }

    /// Deletes the file record as well — used when the person deletes the release.
    public func deleteRemote(_ assetIDs: [UUID]) async {
        guard !assetIDs.isEmpty else { return }
        let ids = assetIDs.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) }
        do {
            _ = try await database.modifyRecords(saving: [], deleting: ids)
        } catch {
            Log.sync.error("Could not delete media records: \(String(describing: error))")
        }
    }

    public func cancel(_ assetIDs: [UUID]) {
        cancelled.formUnion(assetIDs)
    }

    public func clearCancellations() {
        cancelled.removeAll()
    }

    // MARK: - Internals

    private func ensureZone() async throws {
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        }
    }

    private func begin(_ transfer: Transfer) {
        active[transfer.id] = transfer
        let snapshot = Array(active.values)
        Task { [onProgress] in await onProgress?(snapshot) }
    }

    private func finish(_ assetID: UUID) {
        active[assetID] = nil
        let snapshot = Array(active.values)
        Task { [onProgress] in await onProgress?(snapshot) }
    }
}
