import Foundation
import AVFoundation
import DubplateCore

/// Integrated loudness, measured to ITU-R BS.1770-4.
///
/// Informational only. Dubplate never normalises, limits or adjusts a producer's
/// audio — the number sits in the track inspector next to "24-bit / 48 kHz" and
/// nothing acts on it. Measurement runs at utility priority off the main thread and
/// the result is cached on the asset, so a file is measured once.
public struct LoudnessAnalyzer: Sendable {

    /// A single second-order section.
    struct Biquad {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

        /// Direct Form I state, per channel.
        struct State {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        }

        func process(_ sample: Double, state: inout State) -> Double {
            let output = b0 * sample + b1 * state.x1 + b2 * state.x2
                - a1 * state.y1 - a2 * state.y2
            state.x2 = state.x1
            state.x1 = sample
            state.y2 = state.y1
            state.y1 = output
            return output
        }
    }

    public init() {}

    public func integratedLoudness(ofFileAt url: URL) async throws -> Double {
        try await Task.detached(priority: .utility) {
            try Self.measure(url)
        }.value
    }

    // MARK: - Measurement

    static func measure(_ url: URL) throws -> Double {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DubplateError(.unreadableAudio, subject: url.lastPathComponent, underlying: error)
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard sampleRate > 0, channelCount > 0, file.length > 0 else { return -.infinity }

        let (shelf, highPass) = kWeighting(sampleRate: sampleRate)
        var shelfState = [Biquad.State](repeating: .init(), count: channelCount)
        var passState = [Biquad.State](repeating: .init(), count: channelCount)

        // 400 ms blocks, 75% overlap, as the specification requires.
        let blockFrames = Int(sampleRate * 0.4)
        let stepFrames = max(1, blockFrames / 4)
        guard blockFrames > 0 else { return -.infinity }

        var ring = [Double](repeating: 0, count: blockFrames)
        var ringFilled = 0
        var ringIndex = 0
        var framesSinceBlock = 0
        var blockLoudness: [Double] = []

        let chunkFrames = AVAudioFrameCount(min(65_536, max(blockFrames, 4_096)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return -.infinity
        }

        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunkFrames)
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }
            guard let channels = buffer.floatChannelData else { break }

            for frame in 0..<frameCount {
                var weightedSquareSum = 0.0
                for channel in 0..<channelCount {
                    let raw = Double(channels[channel][frame])
                    let shelved = shelf.process(raw, state: &shelfState[channel])
                    let filtered = highPass.process(shelved, state: &passState[channel])
                    // Left and right carry a weight of 1.0. Dubplate does not
                    // measure surround material, so no other weights apply.
                    weightedSquareSum += filtered * filtered
                }
                ring[ringIndex] = weightedSquareSum
                ringIndex = (ringIndex + 1) % blockFrames
                ringFilled = min(ringFilled + 1, blockFrames)
                framesSinceBlock += 1

                if ringFilled == blockFrames, framesSinceBlock >= stepFrames {
                    framesSinceBlock = 0
                    let mean = ring.reduce(0, +) / Double(blockFrames)
                    if mean > 0 {
                        blockLoudness.append(-0.691 + 10 * log10(mean))
                    }
                }
            }
        }

        return gatedLoudness(blocks: blockLoudness)
    }

    /// Two-stage gating: an absolute floor at -70 LUFS, then a relative floor 10 LU
    /// below the mean of what survives the first pass.
    static func gatedLoudness(blocks: [Double]) -> Double {
        let aboveAbsolute = blocks.filter { $0 > -70 }
        guard !aboveAbsolute.isEmpty else { return -.infinity }

        let firstPassMean = meanLoudness(of: aboveAbsolute)
        let relativeThreshold = firstPassMean - 10
        let aboveRelative = aboveAbsolute.filter { $0 > relativeThreshold }
        guard !aboveRelative.isEmpty else { return firstPassMean }
        return meanLoudness(of: aboveRelative)
    }

    /// Averaging happens in the power domain, not the decibel domain.
    private static func meanLoudness(of blocks: [Double]) -> Double {
        let power = blocks.reduce(0.0) { $0 + pow(10, ($1 + 0.691) / 10) }
        return -0.691 + 10 * log10(power / Double(blocks.count))
    }

    // MARK: - K-weighting

    /// The two filters of the K-weighting curve, derived for any sample rate from
    /// the design parameters in the specification rather than hard-coded for
    /// 48 kHz. At 48 kHz these reproduce the coefficients printed in BS.1770-4 to
    /// within 4e-14, which `LoudnessAnalyzerTests` asserts.
    static func kWeighting(sampleRate: Double) -> (Biquad, Biquad) {
        (
            highShelf(
                sampleRate: sampleRate,
                frequency: 1_681.974450955533,
                gainDB: 3.999843853973347,
                q: 0.7071752369554196
            ),
            highPass(
                sampleRate: sampleRate,
                frequency: 38.13547087602444,
                q: 0.5003270373238773
            )
        )
    }

    /// The specification's stage 1. Written with the bilinear `tan` substitution
    /// rather than the cookbook shelf formula, because only this form reproduces
    /// the published coefficients.
    static func highShelf(sampleRate: Double, frequency: Double, gainDB: Double, q: Double) -> Biquad {
        let k = tan(Double.pi * frequency / sampleRate)
        let shelfGain = pow(10, gainDB / 20)
        // The exponent is part of the specification's filter design, not a tuning
        // constant: it sets the shelf's mid-band behaviour.
        let bandGain = pow(shelfGain, 0.499666774155)
        let denominator = 1 + k / q + k * k
        return Biquad(
            b0: (shelfGain + bandGain * k / q + k * k) / denominator,
            b1: 2 * (k * k - shelfGain) / denominator,
            b2: (shelfGain - bandGain * k / q + k * k) / denominator,
            a1: 2 * (k * k - 1) / denominator,
            a2: (1 - k / q + k * k) / denominator
        )
    }

    /// The specification's stage 2. The numerator is exactly `1, -2, 1`: the filter
    /// is deliberately not normalised to unity in the passband.
    static func highPass(sampleRate: Double, frequency: Double, q: Double) -> Biquad {
        let k = tan(Double.pi * frequency / sampleRate)
        let denominator = 1 + k / q + k * k
        return Biquad(
            b0: 1,
            b1: -2,
            b2: 1,
            a1: 2 * (k * k - 1) / denominator,
            a2: (1 - k / q + k * k) / denominator
        )
    }
}
