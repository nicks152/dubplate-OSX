import Foundation

/// A file that has been copied into the media store and read, but not yet recorded.
public struct IngestedFile: Sendable {
    public var assetID: UUID
    public var relativePath: String
    public var originalFilename: String
    public var fileSize: Int64
    public var checksum: String
    public var info: AudioFileInfo
    /// The folder the file was dragged from, kept for display.
    public var sourceFolder: String?

    public init(
        assetID: UUID,
        relativePath: String,
        originalFilename: String,
        fileSize: Int64,
        checksum: String,
        info: AudioFileInfo,
        sourceFolder: String? = nil
    ) {
        self.assetID = assetID
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.fileSize = fileSize
        self.checksum = checksum
        self.info = info
        self.sourceFolder = sourceFolder
    }
}

/// Copies files into the media store and reads them, off the main thread.
///
/// An actor rather than a queue because the work is genuinely serial per file and
/// the state it protects — the store root — is shared. Copying a gigabyte of WAV
/// must never happen on the main actor, and neither must hashing it.
public actor MediaIngestor {
    private let store: MediaStore
    private let inspector: any AudioFileInspecting

    public init(store: MediaStore, inspector: any AudioFileInspecting) {
        self.store = store
        self.inspector = inspector
    }

    /// Copies an audio file in, hashes it and reads its format.
    public func ingestAudio(from source: URL) async throws -> IngestedFile {
        let assetID = UUID()
        let result: (assetID: UUID, relativePath: String, fileSize: Int64)
        do {
            result = try store.ingest(contentsOf: source, area: .audio, assetID: assetID)
        } catch {
            throw DubplateError(.importFailed, subject: source.lastPathComponent, underlying: error)
        }

        let destination = store.url(forRelativePath: result.relativePath)
        let checksum = (try? Checksum.signature(ofFileAt: destination)) ?? ""

        do {
            let info = try await inspector.inspect(fileAt: destination)
            return IngestedFile(
                assetID: assetID,
                relativePath: result.relativePath,
                originalFilename: source.lastPathComponent,
                fileSize: result.fileSize,
                checksum: checksum,
                info: info,
                sourceFolder: source.deletingLastPathComponent().lastPathComponent
            )
        } catch {
            // The bytes are safely stored; only reading them failed. Keep the file
            // so the person can still see it and retry, but report the failure.
            try? store.remove(relativePath: result.relativePath)
            throw DubplateError(.unreadableAudio, subject: source.lastPathComponent, underlying: error)
        }
    }

    /// Copies an image or video in. Dimensions are filled in by the caller, which
    /// has access to the platform image APIs.
    public func ingestArtwork(from source: URL) throws -> IngestedFile {
        let assetID = UUID()
        do {
            let result = try store.ingest(contentsOf: source, area: .artwork, assetID: assetID)
            let destination = store.url(forRelativePath: result.relativePath)
            return IngestedFile(
                assetID: assetID,
                relativePath: result.relativePath,
                originalFilename: source.lastPathComponent,
                fileSize: result.fileSize,
                checksum: (try? Checksum.signature(ofFileAt: destination)) ?? "",
                info: AudioFileInfo()
            )
        } catch {
            throw DubplateError(.importFailed, subject: source.lastPathComponent, underlying: error)
        }
    }

    public func removeMedia(atRelativePath path: String) {
        try? store.remove(relativePath: path)
    }
}
