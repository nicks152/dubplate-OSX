import Foundation
import SwiftData

/// A cover, a looping release visual, or a track canvas.
@Model
public final class ArtworkAsset {
    public var id: UUID = UUID()
    public var kindRaw: String = ArtworkKind.staticArtwork.rawValue
    public var filename: String = ""
    public var originalFilename: String = ""
    public var relativePath: String = ""
    public var cloudRecordName: String?
    public var width: Int = 0
    public var height: Int = 0
    public var fileSize: Int64 = 0
    public var checksum: String = ""
    public var createdAt: Date = Date.distantPast
    public var availabilityRaw: String = AvailabilityState.local.rawValue
    /// Seconds into a video where the loop should start, for trimmed motion artwork.
    public var loopStart: TimeInterval = 0
    /// Loop length in seconds. Zero means "the whole file".
    public var loopDuration: TimeInterval = 0
    /// Whether the source video's own audio should be silenced during playback.
    public var mutesSourceAudio: Bool = true
    /// A small JPEG rendition used for lists, remote command centre artwork and the
    /// Lock Screen so nothing decodes a 4000px cover on a scroll.
    public var thumbnailData: Data?

    public init(
        id: UUID = UUID(),
        kind: ArtworkKind = .staticArtwork,
        filename: String = "",
        originalFilename: String = "",
        relativePath: String = "",
        width: Int = 0,
        height: Int = 0,
        fileSize: Int64 = 0,
        checksum: String = "",
        availability: AvailabilityState = .local,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.filename = filename
        self.originalFilename = originalFilename
        self.relativePath = relativePath
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.checksum = checksum
        self.availabilityRaw = availability.rawValue
        self.createdAt = createdAt
    }

    public var kind: ArtworkKind {
        get { ArtworkKind(rawValue: kindRaw) ?? .staticArtwork }
        set { kindRaw = newValue.rawValue }
    }

    public var availability: AvailabilityState {
        get { AvailabilityState(rawValue: availabilityRaw) ?? .local }
        set { availabilityRaw = newValue.rawValue }
    }

    public var pixelSummary: String {
        "\(width) × \(height)"
    }

    /// Covers below this are noticeably soft on a 6.9" display at full width.
    public static let recommendedMinimumEdge = 1400

    public var isLowResolution: Bool {
        kind == .staticArtwork && min(width, height) > 0 && min(width, height) < Self.recommendedMinimumEdge
    }

    public var isSquare: Bool {
        width > 0 && width == height
    }
}
