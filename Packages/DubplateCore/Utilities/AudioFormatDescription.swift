import Foundation

/// What a file actually is, as reported by the system when it was imported.
///
/// Dubplate never converts audio, so this is descriptive rather than prescriptive:
/// it exists so the interface can say "24-bit / 48 kHz" and so the playback engine
/// knows when a sample-rate change is coming between two tracks.
public struct AudioFormatDescription: Hashable, Codable, Sendable {
    public var sampleRate: Double
    public var bitDepth: Int
    public var channelCount: Int
    /// A short, human-facing name: "WAV", "AIFF", "ALAC", "AAC", "FLAC", "MP3".
    public var codec: String

    public init(sampleRate: Double = 0, bitDepth: Int = 0, channelCount: Int = 0, codec: String = "") {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channelCount = channelCount
        self.codec = codec
    }

    public static let unknown = AudioFormatDescription()

    public var isKnown: Bool {
        sampleRate > 0 && channelCount > 0
    }

    /// "48 kHz", "96 kHz", "44.1 kHz".
    public var sampleRateSummary: String {
        guard sampleRate > 0 else { return "" }
        let kilohertz = sampleRate / 1000
        if kilohertz == kilohertz.rounded() {
            return "\(Int(kilohertz)) kHz"
        }
        return String(format: "%.1f kHz", kilohertz)
    }

    public var channelSummary: String {
        switch channelCount {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 0: return ""
        default: return "\(channelCount) ch"
        }
    }

    public var depthSummary: String {
        guard bitDepth > 0 else { return "" }
        // 32-bit float files report a depth of 32; the engine flags them separately.
        return "\(bitDepth)-bit"
    }

    /// "24-bit · 48 kHz · Stereo", skipping anything that is unknown.
    public var summary: String {
        [depthSummary, sampleRateSummary, channelSummary]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// "24-bit / 48 kHz" — the compact form used in the track inspector.
    public var compactSummary: String {
        [depthSummary, sampleRateSummary]
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    /// Two formats can be played back-to-back without reconfiguring the engine.
    public func isGaplessCompatible(with other: AudioFormatDescription) -> Bool {
        sampleRate == other.sampleRate && channelCount == other.channelCount
    }
}
