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

    /// One file on the move.
    ///
    /// No fraction: the async `modifyRecords`/`record(for:)` APIs report none, and a
    /// progress bar frozen at zero for the length of a 300 MB transfer is a worse
    /// lie than a word.
    public struct Transfer: Sendable, Identifiable {
        public let id: UUID
        public var filename: String
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
                  !descriptor.isUploaded,
                  mediaStore.exists(relativePath: descriptor.relativePath)
            else { continue }

            let url = mediaStore.url(forRelativePath: descriptor.relativePath)
            let record = CKRecord(
                recordType: Self.recordType,
                recordID: CKRecord.ID(recordName: assetID.uuidString, zoneID: zoneID)
            )
            record[Self.assetIDField] = assetID.uuidString
            record[Self.fileField] = CKAsset(fileURL: url)

            begin(Transfer(id: assetID, filename: descriptor.originalFilename, isUpload: true))
            do {
                let response = try await database.modifyRecords(
                    saving: [record],
                    deleting: [],
                    savePolicy: .allKeys
                )
                // `modifyRecords` does not throw when an individual record fails —
                // it reports per-record results. Ignoring them meant a quota-exceeded
                // upload was recorded as a success, and "Remove Download" would then
                // happily delete the only copy of a master.
                try await recordOutcome(of: response.saveResults[record.recordID], for: assetID, descriptor: descriptor)
            } catch let error as CKError where error.code == .serverRecordChanged {
                // Already up there. Assets never change once written, so this is a
                // success, not a conflict.
                await index.markUploaded(assetID)
                await onAvailabilityChanged?(assetID, .available)
            } catch {
                await note(failure: error, for: assetID, descriptor: descriptor)
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

            begin(Transfer(id: assetID, filename: descriptor.originalFilename, isUpload: false))
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

    /// Deletes local bytes but never the cloud copy.
    ///
    /// The local flag is not enough to act on: it can be wrong, and being wrong here
    /// destroys a master. Every file is confirmed present in CloudKit — by asking
    /// CloudKit — before anything is unlinked.
    public func removeLocalCopies(_ assetIDs: [UUID]) async {
        for assetID in assetIDs {
            guard let descriptor = await index.descriptor(for: assetID) else { continue }
            guard descriptor.isUploaded else {
                Log.sync.info("Refusing to remove a local file that has not been uploaded")
                continue
            }
            guard await remoteFileExists(assetID) else {
                Log.sync.error(
                    "The index says \(descriptor.originalFilename, privacy: .public) is in iCloud "
                    + "and iCloud disagrees. Keeping the local copy."
                )
                await index.markNotUploaded(assetID)
                await onError?(DubplateError(.transferFailed, subject: descriptor.originalFilename))
                continue
            }
            try? mediaStore.remove(relativePath: descriptor.relativePath)
            await onAvailabilityChanged?(assetID, .cloudOnly)
        }
    }

    /// Asks CloudKit whether the file record is actually there, without fetching it.
    private func remoteFileExists(_ assetID: UUID) async -> Bool {
        let recordID = CKRecord.ID(recordName: assetID.uuidString, zoneID: zoneID)
        do {
            let results = try await database.records(for: [recordID], desiredKeys: [])
            if case .success = results[recordID] { return true }
            return false
        } catch {
            // Cannot confirm, so do not delete.
            Log.sync.error("Could not confirm the iCloud copy: \(String(describing: error))")
            return false
        }
    }

    /// Deletes the file record as well — used when the person deletes the release.
    public func deleteRemote(_ assetIDs: [UUID]) async {
        guard !assetIDs.isEmpty else { return }
        let ids = assetIDs.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) }
        do {
            let response = try await database.modifyRecords(saving: [], deleting: ids)
            for (recordID, result) in response.deleteResults {
                if case .failure(let error) = result {
                    Log.sync.error(
                        "Could not delete \(recordID.recordName, privacy: .public): \(String(describing: error))"
                    )
                }
            }
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

    /// Called when something goes wrong that a person should hear about.
    public var onError: (@Sendable (DubplateError) async -> Void)?

    public func setErrorHandler(_ handler: @escaping @Sendable (DubplateError) async -> Void) {
        onError = handler
    }

    // MARK: - Results

    private func recordOutcome(
        of result: Result<CKRecord, any Error>?,
        for assetID: UUID,
        descriptor: MediaDescriptor
    ) async throws {
        guard let result else {
            // No result for the record we sent: treat as not uploaded rather than
            // assuming success.
            await onAvailabilityChanged?(assetID, .local)
            return
        }
        switch result {
        case .success:
            await index.markUploaded(assetID)
            await onAvailabilityChanged?(assetID, .available)
            Log.sync.info("Uploaded \(descriptor.originalFilename, privacy: .public)")
        case .failure(let error):
            if let ckError = error as? CKError, ckError.code == .serverRecordChanged {
                await index.markUploaded(assetID)
                await onAvailabilityChanged?(assetID, .available)
                return
            }
            await note(failure: error, for: assetID, descriptor: descriptor)
        }
    }

    private func note(failure error: any Error, for assetID: UUID, descriptor: MediaDescriptor) async {
        Log.sync.error(
            "Upload failed for \(descriptor.originalFilename, privacy: .public): \(String(describing: error))"
        )
        await onAvailabilityChanged?(assetID, .local)
        guard let ckError = error as? CKError else {
            await onError?(DubplateError(.transferFailed, subject: descriptor.originalFilename, underlying: error))
            return
        }
        switch ckError.code {
        case .quotaExceeded:
            await onError?(DubplateError(.storageFull, subject: descriptor.originalFilename))
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited:
            // The engine retries these on its own schedule; not worth interrupting
            // anyone over.
            break
        default:
            await onError?(DubplateError(.transferFailed, subject: descriptor.originalFilename, underlying: error))
        }
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
