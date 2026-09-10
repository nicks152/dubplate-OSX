import Foundation
import DubplateCore

/// What the sync layer knows about a piece of media.
///
/// Deliberately independent of SwiftData: the transfer layer must be able to build
/// an upload, or place a download, without faulting model objects in from whatever
/// context happens to be alive. It is also what makes the queue survive a relaunch
/// halfway through uploading a forty-minute WAV.
public struct MediaDescriptor: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case audio
        case artwork
    }

    public var assetID: UUID
    public var kind: Kind
    public var relativePath: String
    public var originalFilename: String
    public var checksum: String
    public var fileSize: Int64
    /// Set once the *description* of this file has reached CloudKit. Says nothing
    /// about the bytes.
    public var isDescribed: Bool
    /// Set once the bytes themselves are known to be in CloudKit.
    ///
    /// These are two different record types on two different code paths, and
    /// conflating them meant a file whose description had synced was treated as
    /// safely backed up — after which "Remove Download" deleted the only copy.
    public var isUploaded: Bool

    public init(
        assetID: UUID,
        kind: Kind,
        relativePath: String,
        originalFilename: String,
        checksum: String,
        fileSize: Int64,
        isDescribed: Bool = false,
        isUploaded: Bool = false
    ) {
        self.assetID = assetID
        self.kind = kind
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.checksum = checksum
        self.fileSize = fileSize
        self.isDescribed = isDescribed
        self.isUploaded = isUploaded
    }

    public var recordName: String { assetID.uuidString }
}

/// A small, durable index of every piece of media, stored as one JSON file.
///
/// One file rather than a second database: it is a few hundred bytes per asset,
/// it is rewritten atomically, and losing it costs nothing — it can be rebuilt from
/// the library, and until it is, the worst case is re-uploading bytes CloudKit
/// already has.
public actor MediaIndex {
    private let url: URL
    private var descriptors: [UUID: MediaDescriptor] = [:]
    private var isLoaded = false
    /// True when the file on disk could not be read. Nothing is written back until
    /// something has been recorded, so an unreadable index is never overwritten with
    /// an empty one before it can be rebuilt from the library.
    private var isRecovering = false
    private var isDirty = false
    private var flushTask: Task<Void, Never>?

    public init(directory: URL) {
        self.url = directory.appending(path: "media-index.json", directoryHint: .notDirectory)
    }

    public func all() -> [MediaDescriptor] {
        load()
        return Array(descriptors.values)
    }

    public func descriptor(for assetID: UUID) -> MediaDescriptor? {
        load()
        return descriptors[assetID]
    }

    /// Files whose bytes are not in CloudKit.
    public func pendingUploads() -> [MediaDescriptor] {
        load()
        return descriptors.values.filter { !$0.isUploaded }
    }

    /// Files whose description is not in CloudKit.
    public func pendingDescriptions() -> [MediaDescriptor] {
        load()
        return descriptors.values.filter { !$0.isDescribed }
    }

    public func record(_ descriptor: MediaDescriptor) {
        record([descriptor])
    }

    /// Merges rather than replaces: a descriptor rebuilt from the library carries
    /// `isUploaded == false`, and overwriting the real value with it re-uploaded
    /// whole albums.
    public func record(_ newDescriptors: [MediaDescriptor]) {
        load()
        for descriptor in newDescriptors {
            var merged = descriptor
            if let existing = descriptors[descriptor.assetID] {
                merged.isUploaded = existing.isUploaded || descriptor.isUploaded
                merged.isDescribed = existing.isDescribed || descriptor.isDescribed
            }
            descriptors[descriptor.assetID] = merged
        }
        markDirty()
    }

    /// The bytes are in CloudKit.
    public func markUploaded(_ assetID: UUID) {
        load()
        descriptors[assetID]?.isUploaded = true
        markDirty()
    }

    public func markNotUploaded(_ assetID: UUID) {
        load()
        descriptors[assetID]?.isUploaded = false
        markDirty()
    }

    /// The description is in CloudKit. Not the same thing, and not sufficient.
    public func markDescribed(_ assetID: UUID) {
        load()
        descriptors[assetID]?.isDescribed = true
        markDirty()
    }

    /// Used when an account changes: the bytes may not be in the new account.
    public func markEverythingNotUploaded() {
        load()
        for key in descriptors.keys {
            descriptors[key]?.isUploaded = false
            descriptors[key]?.isDescribed = false
        }
        markDirty()
    }

    public func remove(_ assetID: UUID) {
        load()
        descriptors[assetID] = nil
        markDirty()
    }

    /// Writes anything outstanding now. Called before the process is likely to end.
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        if isDirty { persist() }
    }

    /// Coalesces writes.
    ///
    /// A first sync marks thousands of assets uploaded one at a time; rewriting the
    /// whole file on each of them is quadratic in bytes written and was by some
    /// distance the worst hot spot in the sync layer.
    private func markDirty() {
        isDirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            await self?.performScheduledFlush()
        }
    }

    private func performScheduledFlush() {
        flushTask = nil
        guard isDirty else { return }
        persist()
    }

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let decoded = try JSONDecoder().decode([MediaDescriptor].self, from: data)
            descriptors = Dictionary(uniqueKeysWithValues: decoded.map { ($0.assetID, $0) })
        } catch {
            isRecovering = true
            Log.sync.error("Media index unreadable, starting a new one: \(String(describing: error))")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Array(descriptors.values))
            try data.write(to: url, options: .atomic)
        } catch {
            Log.sync.error("Could not write media index: \(String(describing: error))")
        }
    }
}
