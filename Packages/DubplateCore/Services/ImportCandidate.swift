import Foundation

/// One file on its way into Dubplate, before anything has been written.
public struct ImportCandidate: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let filename: String
    public let fileSize: Int64
    public let creationDate: Date?
    /// Position in the drop, which is the order Finder was showing the files in.
    public let dropIndex: Int
    public let parsed: ParsedFilename

    public init(
        url: URL,
        dropIndex: Int,
        fileSize: Int64 = 0,
        creationDate: Date? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.url = url
        self.filename = url.lastPathComponent
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.dropIndex = dropIndex
        self.parsed = FilenameParser.parse(url.lastPathComponent)
    }

    public var isAudio: Bool { FilenameParser.isAudio(filename) }
    public var isImage: Bool { FilenameParser.isImage(filename) }
    public var isVideo: Bool { FilenameParser.isVideo(filename) }

    /// Reads size and creation date off disk. Failures are not fatal — a file with
    /// no readable attributes still imports, it just orders by drop position.
    public static func make(url: URL, dropIndex: Int) -> ImportCandidate {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
        return ImportCandidate(
            url: url,
            dropIndex: dropIndex,
            fileSize: Int64(values?.fileSize ?? 0),
            creationDate: values?.creationDate
        )
    }
}
