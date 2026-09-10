import Foundation
import AVFoundation
import DubplateCore

/// Reads what a file is without changing it.
///
/// Everything reported here comes from the file's own format, not the format the
/// engine will render in: a 96 kHz/24-bit master reports 96 kHz/24-bit even on a
/// device whose output is running at 48 kHz.
public struct AudioFileInspector: AudioFileInspecting {

    public init() {}

    public func inspect(fileAt url: URL) async throws -> AudioFileInfo {
        try await Task.detached(priority: .userInitiated) {
            try Self.read(url)
        }.value
    }

    /// Synchronous read, used by the detached task above and by tests.
    public static func read(_ url: URL) throws -> AudioFileInfo {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DubplateError(.unreadableAudio, subject: url.lastPathComponent, underlying: error)
        }

        let fileFormat = file.fileFormat
        let description = fileFormat.streamDescription.pointee
        let sampleRate = fileFormat.sampleRate
        let frames = file.length
        let duration = sampleRate > 0 ? Double(frames) / sampleRate : 0

        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var bitDepth = Int(description.mBitsPerChannel)
        if bitDepth == 0 {
            // Compressed formats carry no channel bit depth. Take it from the
            // settings dictionary when it is there, and say nothing when it is not
            // rather than inventing a number for the inspector to display.
            bitDepth = fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 0
        }

        let info = AudioFileInfo(
            duration: duration,
            format: AudioFormatDescription(
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                channelCount: Int(fileFormat.channelCount),
                codec: codecName(for: description.mFormatID, url: url)
            ),
            isFloatingPoint: isFloat
        )

        guard info.duration > 0, info.format.channelCount > 0 else {
            throw DubplateError(.unreadableAudio, subject: url.lastPathComponent)
        }
        return info
    }

    /// A name a person would recognise, not a four-character code.
    static func codecName(for formatID: AudioFormatID, url: URL) -> String {
        switch formatID {
        case kAudioFormatLinearPCM:
            switch url.pathExtension.lowercased() {
            case "aif", "aiff", "aifc": return "AIFF"
            case "caf": return "CAF"
            default: return "WAV"
            }
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatOpus: return "Opus"
        default: return url.pathExtension.uppercased()
        }
    }
}
