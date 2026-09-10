import Foundation

/// What Dubplate learns about a file by opening it.
public struct AudioFileInfo: Hashable, Sendable {
    public var duration: TimeInterval
    public var format: AudioFormatDescription
    /// True for 32-bit float files, which are common out of modern DAWs.
    public var isFloatingPoint: Bool

    public init(
        duration: TimeInterval = 0,
        format: AudioFormatDescription = .unknown,
        isFloatingPoint: Bool = false
    ) {
        self.duration = duration
        self.format = format
        self.isFloatingPoint = isFloatingPoint
    }
}

/// Reads duration and format from an audio file.
///
/// A protocol for exactly one reason: the real implementation lives in
/// DubplateAudio (it needs AVFoundation) and DubplateCore must not depend on it.
/// Tests substitute a stub so importing can be exercised without touching audio.
public protocol AudioFileInspecting: Sendable {
    func inspect(fileAt url: URL) async throws -> AudioFileInfo
}

/// Used by tests and previews. Reports a plausible file rather than reading one.
public struct StubAudioInspector: AudioFileInspecting {
    public var info: AudioFileInfo

    public init(info: AudioFileInfo = AudioFileInfo(
        duration: 210,
        format: AudioFormatDescription(sampleRate: 48_000, bitDepth: 24, channelCount: 2, codec: "WAV")
    )) {
        self.info = info
    }

    public func inspect(fileAt url: URL) async throws -> AudioFileInfo {
        info
    }
}
