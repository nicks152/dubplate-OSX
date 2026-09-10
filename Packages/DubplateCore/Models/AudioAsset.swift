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
    public var availabilityRaw: String = AvailabilityState.local.rawValue
    /// Integrated loudness in LUFS, computed lazily in the background. Informational.
    public var integratedLoudness: Double?
    /// Peaks for the scrubber, stored as bytes (one unsigned byte per bucket).
    public var waveformPeaks: Data?

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
        self.availabilityRaw = availability.rawValue
        self.createdAt = createdAt
    }

    public var availability: AvailabilityState {
        get { AvailabilityState(rawValue: availabilityRaw) ?? .local }
        set { availabilityRaw = newValue.rawValue }
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

    /// "-10.8 LUFS", or `nil` while the value has not been measured.
    public var loudnessSummary: String? {
        guard let integratedLoudness, integratedLoudness.isFinite else { return nil }
        return String(format: "%.1f LUFS", integratedLoudness)
    }
}
