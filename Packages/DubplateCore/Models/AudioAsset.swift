import Foundation
import SwiftData

/// A file of audio inside Dubplate's managed media store.
///
/// The location is stored as a path *relative to the media store root*, never as an
/// absolute URL: an iOS application container is re-created with a new UUID on every
/// install, so absolute paths persisted today are wrong tomorrow. Resolve with
/// `MediaStore.url(for:)`.
@Model
public final class AudioAsset {
    public var id: UUID = UUID()
    /// Name inside the media store, e.g. `A1B2…-midnight-mix-5.wav`.
    public var filename: String = ""
    /// The name the file had in Finder when it was imported. Shown to people.
    public var originalFilename: String = ""
    /// The folder it was dragged from, for display only — never resolved or opened.
    /// "Midnight mix 5.wav" exists in six bounce folders; this is how a producer
    /// tells which one they are listening to.
    public var sourceFolder: String?
    /// Path relative to the media store root.
    public var relativePath: String = ""
    /// Record name in the private CloudKit database, once uploaded.
    public var cloudRecordName: String?
    public var duration: TimeInterval = 0
    public var sampleRate: Double = 0
    public var bitDepth: Int = 0
    public var channelCount: Int = 0
    public var codec: String = ""
    public var fileSize: Int64 = 0
    public var createdAt: Date = Date.distantPast
    /// SHA-256 of the file bytes, used to recognise a re-import of the same bounce.
    public var checksum: String = ""

    /// Whether the bytes are on *this* device.
    ///
    /// Deliberately not persisted and therefore never synced: "is this file here"
    /// is a different answer on the Mac and on the phone, and a stored value would
    /// mean the phone telling the Mac that the Mac's own master is unavailable.
    /// `nil` means "not looked yet", which is treated as available — the playback
    /// path checks the file itself before it opens it.
    @Transient
    public var localPresence: Bool?

    /// Set only while a transfer is in flight or has just failed. In memory only.
    @Transient
    public var transferState: AvailabilityState?
    /// Integrated loudness in LUFS, computed lazily in the background. Informational.
    public var integratedLoudness: Double?
    /// Peaks for the scrubber, stored as bytes (one unsigned byte per bucket).
    public var waveformPeaks: Data?

    /// The versions backed by this file. Usually one — but the same master can sit
    /// on a single and on the album, and then it is two.
    @Relationship(deleteRule: .nullify, inverse: \TrackVersion.audioAsset)
    public var versions: [TrackVersion]?

    public init(
        id: UUID = UUID(),
        filename: String = "",
        originalFilename: String = "",
        relativePath: String = "",
        duration: TimeInterval = 0,
        format: AudioFormatDescription = .unknown,
        fileSize: Int64 = 0,
        checksum: String = "",
        availability: AvailabilityState = .local,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.originalFilename = originalFilename
        self.relativePath = relativePath
        self.duration = duration
        self.sampleRate = format.sampleRate
        self.bitDepth = format.bitDepth
        self.channelCount = format.channelCount
        self.codec = format.codec
        self.fileSize = fileSize
        self.checksum = checksum
        self.localPresence = availability.isPlayableNow
        self.createdAt = createdAt
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

    public var format: AudioFormatDescription {
        AudioFormatDescription(
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channelCount: channelCount,
            codec: codec
        )
    }

    /// "24-bit · 48 kHz · Stereo"
    public var formatSummary: String {
        format.summary
    }

    /// "24-bit / 48 kHz" — the denser form for inline metadata lines.
    public var compactFormat: String {
        format.compactSummary
    }

    /// "-10.8 LUFS", or `nil` while the value has not been measured.
    public var loudnessSummary: String? {
        guard let integratedLoudness, integratedLoudness.isFinite else { return nil }
        return String(format: "%.1f LUFS", integratedLoudness)
    }
}
