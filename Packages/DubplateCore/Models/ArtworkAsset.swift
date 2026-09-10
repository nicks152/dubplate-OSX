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

    /// Per-device, so not persisted. See `AudioAsset.localPresence`.
    @Transient
    public var localPresence: Bool?

    @Transient
    public var transferState: AvailabilityState?
    /// Seconds into a video where the loop should start, for trimmed motion artwork.
    public var loopStart: TimeInterval = 0
    /// Loop length in seconds. Zero means "the whole file".
    public var loopDuration: TimeInterval = 0
    /// Whether the source video's own audio should be silenced during playback.
    public var mutesSourceAudio: Bool = true
    /// A small JPEG rendition used for lists, remote command centre artwork and the
    /// Lock Screen so nothing decodes a 4000px cover on a scroll.
    public var thumbnailData: Data?

    // Inverses. CloudKit mirroring refuses a model with an unpaired relationship,
    // and the failure is a store that will not open — which the fallback path then
    // turns into a quiet downgrade to local-only. Release points at artwork twice,
    // so it needs two distinct inverses.
    public var coverForRelease: Release?
    public var motionForRelease: Release?
    public var canvasForTrack: Track?
    public var avatarForProfile: ArtistProfile?

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
        self.localPresence = availability.isPlayableNow
        self.createdAt = createdAt
    }

    public var kind: ArtworkKind {
        get { ArtworkKind(rawValue: kindRaw) ?? .staticArtwork }
        set { kindRaw = newValue.rawValue }
    }

    public var availability: AvailabilityState {
        get {
            if let transferState { return transferState }
            guard let localPresence else { return .available }
            return localPresence ? .available : .cloudOnly
        }
        set {
            switch newValue {
            case .available, .local:
                localPresence = true
                transferState = nil
            case .cloudOnly:
                localPresence = false
                transferState = nil
            case .downloading, .error, .missing:
                transferState = newValue
            }
        }
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
