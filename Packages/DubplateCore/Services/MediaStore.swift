import Foundation

/// Where Dubplate keeps the actual audio and image files.
///
/// Layout, relative to the store root:
///
///     Audio/<first two characters of asset id>/<asset id>.<ext>
///     Artwork/<first two characters of asset id>/<asset id>.<ext>
///     Inbox/…            loose imports that are not on a release yet
///
/// The two-character fan-out keeps directory listings small on libraries with
/// thousands of bounces. Nothing outside this type builds a media path, and
/// nothing persists an absolute one: iOS re-creates the application container
/// with a new UUID on every install, so absolute paths written today are wrong
/// after the next update.
public struct MediaStore: Sendable {
    public enum Area: String, Sendable {
        case audio = "Audio"
        case artwork = "Artwork"

        var directoryName: String { rawValue }
    }

    public let root: URL

    /// `FileManager` is not `Sendable`, and a `MediaStore` crosses actor boundaries
    /// constantly. `FileManager.default` is documented as safe to use from multiple
    /// threads, so the store holds nothing but its root and reaches for the shared
    /// instance where it needs one.
    private var fileManager: FileManager { .default }

    public init(root: URL) {
        self.root = root
    }

    /// The default location: `Application Support/Dubplate/Media`.
    public static func makeDefault() throws -> MediaStore {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appending(path: "Dubplate", directoryHint: .isDirectory)
            .appending(path: "Media", directoryHint: .isDirectory)
        let store = MediaStore(root: root)
        try store.prepare()
        return store
    }

    public func prepare() throws {
        for area in [Area.audio, Area.artwork] {
            try fileManager.createDirectory(
                at: root.appending(path: area.directoryName, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        try excludeFromDeviceBackup()
    }

    // MARK: - Paths

    /// The relative path an asset with this identifier and extension will live at.
    public func relativePath(area: Area, assetID: UUID, fileExtension: String) -> String {
        let identifier = assetID.uuidString
        let shard = String(identifier.prefix(2))
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension.lowercased())"
        return "\(area.directoryName)/\(shard)/\(identifier)\(suffix)"
    }

    /// Resolves a stored relative path against this device's store root.
    public func url(forRelativePath path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    public func exists(relativePath path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return fileManager.fileExists(atPath: url(forRelativePath: path).path(percentEncoded: false))
    }

    // MARK: - Writing

    /// Copies a source file into the store and returns where it landed.
    ///
    /// Always a copy, never a move: the file in the producer's bounce folder is
    /// theirs, and Dubplate never takes it away. Uses a temporary name and an
    /// atomic replace so a crash mid-copy cannot leave a half file that later
    /// looks like a valid asset.
    @discardableResult
    public func ingest(
        contentsOf source: URL,
        area: Area,
        assetID: UUID = UUID()
    ) throws -> (assetID: UUID, relativePath: String, fileSize: Int64) {
        let fileExtension = source.pathExtension
        let path = relativePath(area: area, assetID: assetID, fileExtension: fileExtension)
        let destination = url(forRelativePath: path)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let staging = destination.deletingLastPathComponent()
            .appending(path: ".incoming-\(assetID.uuidString)", directoryHint: .notDirectory)
        if fileManager.fileExists(atPath: staging.path(percentEncoded: false)) {
            try fileManager.removeItem(at: staging)
        }

        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        try fileManager.copyItem(at: source, to: staging)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            // One atomic swap rather than remove-then-move, which leaves a window
            // where the asset exists in the database and not on disk.
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }

        let size = (try? Checksum.fileSize(of: destination)) ?? 0
        return (assetID, path, size)
    }

    /// Moves a downloaded temporary file into place.
    public func adopt(temporaryFile: URL, asRelativePath path: String) throws {
        let destination = url(forRelativePath: path)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryFile)
        } else {
            try fileManager.moveItem(at: temporaryFile, to: destination)
        }
    }

    public func remove(relativePath path: String) throws {
        guard exists(relativePath: path) else { return }
        try fileManager.removeItem(at: url(forRelativePath: path))
    }

    // MARK: - Housekeeping

    /// Total bytes held on this device.
    public func usedBytes() -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return 0
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Deletes staging files left behind by an interrupted import or download.
    @discardableResult
    public func removeOrphanedStagingFiles() -> Int {
        var removed = 0
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return 0
        }
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix(".incoming-") {
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Media is reproducible from iCloud and can be very large, so it stays out of
    /// device backups. Metadata — the part that is irreplaceable — is not excluded.
    private func excludeFromDeviceBackup() throws {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
