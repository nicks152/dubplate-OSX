import Foundation
import AVFoundation
import DubplateCore

/// Builds the peak data behind the scrubber.
///
/// One unsigned byte per bucket: enough resolution to draw a recognisable shape at
/// any width, small enough to keep next to the asset (a 400-bucket waveform is 400
/// bytes) and cheap enough to compute once and never again. Reading happens in
/// 64k-frame chunks so a 45-minute 96/24 master never lands in memory whole.
public struct WaveformGenerator: Sendable {

    public static let defaultBucketCount = 400

    public init() {}

    public func peaks(forFileAt url: URL, buckets: Int = defaultBucketCount) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try Self.read(url, buckets: buckets)
        }.value
    }

    static func read(_ url: URL, buckets: Int) throws -> Data {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DubplateError(.unreadableAudio, subject: url.lastPathComponent, underlying: error)
        }

        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, buckets > 0 else { return Data() }

        let framesPerBucket = max(1, Int(totalFrames) / buckets)
        let chunkFrames = AVAudioFrameCount(min(65_536, max(framesPerBucket, 4_096)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return Data()
        }

        var output = [UInt8]()
        output.reserveCapacity(buckets)
        var bucketPeak: Float = 0
        var framesInBucket = 0

        while file.framePosition < totalFrames {
            if Task.isCancelled { return Data() }
            try file.read(into: buffer, frameCount: chunkFrames)
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)

            for frame in 0..<frameCount {
                var magnitude: Float = 0
                for channel in 0..<channelCount {
                    magnitude = max(magnitude, abs(channels[channel][frame]))
                }
                bucketPeak = max(bucketPeak, magnitude)
                framesInBucket += 1
                if framesInBucket >= framesPerBucket {
                    output.append(quantise(bucketPeak))
                    bucketPeak = 0
                    framesInBucket = 0
                    if output.count >= buckets { break }
                }
            }
            if output.count >= buckets { break }
        }
        if output.count < buckets, framesInBucket > 0 {
            output.append(quantise(bucketPeak))
        }
        return Data(output)
    }

    /// Peaks are stored on a square-root curve: quiet detail stays visible at 8-bit
    /// resolution, which a linear mapping loses entirely.
    private static func quantise(_ peak: Float) -> UInt8 {
        let clamped = min(max(peak, 0), 1)
        return UInt8(min(255, (sqrt(clamped) * 255).rounded()))
    }

    /// Reads stored peaks back as normalised heights for drawing.
    public static func heights(from data: Data) -> [Double] {
        data.map { Double($0) / 255.0 }
    }
}
