import XCTest
@testable import DubplateAudio

/// The loudness measurement, checked against the numbers in the specification.
///
/// The filters are the part worth testing without an audio file: if the K-weighting
/// is wrong, every measurement is wrong by the same amount and nobody notices.
final class LoudnessAnalyzerTests: XCTestCase {

    /// ITU-R BS.1770-4, table 1: the coefficients for 48 kHz.
    func testKWeightingMatchesTheSpecificationAt48kHz() {
        let (shelf, highPass) = LoudnessAnalyzer.kWeighting(sampleRate: 48_000)
        let tolerance = 1e-10

        XCTAssertEqual(shelf.b0, 1.53512485958697, accuracy: tolerance)
        XCTAssertEqual(shelf.b1, -2.69169618940638, accuracy: tolerance)
        XCTAssertEqual(shelf.b2, 1.19839281085285, accuracy: tolerance)
        XCTAssertEqual(shelf.a1, -1.69065929318241, accuracy: tolerance)
        XCTAssertEqual(shelf.a2, 0.73248077421585, accuracy: tolerance)

        XCTAssertEqual(highPass.b0, 1, accuracy: tolerance)
        XCTAssertEqual(highPass.b1, -2, accuracy: tolerance)
        XCTAssertEqual(highPass.b2, 1, accuracy: tolerance)
        XCTAssertEqual(highPass.a1, -1.99004745483398, accuracy: tolerance)
        XCTAssertEqual(highPass.a2, 0.99007225036621, accuracy: tolerance)
    }

    /// Producers work at 44.1 and 96 as often as at 48, so the filters have to be
    /// derived rather than pasted.
    func testFiltersAreDerivedForOtherSampleRates() {
        for rate in [44_100.0, 88_200.0, 96_000.0] {
            let (shelf, highPass) = LoudnessAnalyzer.kWeighting(sampleRate: rate)
            XCTAssertTrue(shelf.b0.isFinite)
            XCTAssertTrue(highPass.a2.isFinite)
            XCTAssertNotEqual(shelf.a1, 0)
            // A stable filter keeps its poles inside the unit circle.
            XCTAssertLessThan(abs(shelf.a2), 1)
            XCTAssertLessThan(abs(highPass.a2), 1)
        }
    }

    /// A full-scale 1 kHz sine in both channels measures 0 LUFS.
    func testFullScaleSineMeasuresZero() {
        let sampleRate = 48_000.0
        let (shelf, highPass) = LoudnessAnalyzer.kWeighting(sampleRate: sampleRate)
        var shelfState = LoudnessAnalyzer.Biquad.State()
        var passState = LoudnessAnalyzer.Biquad.State()

        let frames = Int(sampleRate * 3)
        var filtered: [Double] = []
        filtered.reserveCapacity(frames)
        for frame in 0..<frames {
            let sample = sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate)
            let shelved = shelf.process(sample, state: &shelfState)
            filtered.append(highPass.process(shelved, state: &passState))
        }

        let blockFrames = Int(sampleRate * 0.4)
        let step = blockFrames / 4
        var blocks: [Double] = []
        var start = 0
        while start + blockFrames <= filtered.count {
            // Two identical channels, so the weighted sum is twice one channel.
            let mean = filtered[start..<(start + blockFrames)]
                .reduce(0) { $0 + 2 * $1 * $1 } / Double(blockFrames)
            if mean > 0 { blocks.append(-0.691 + 10 * log10(mean)) }
            start += step
        }

        let loudness = LoudnessAnalyzer.gatedLoudness(blocks: blocks)
        XCTAssertEqual(loudness, 0, accuracy: 0.1)
    }

    func testSilenceIsNotAMeasurement() {
        XCTAssertEqual(LoudnessAnalyzer.gatedLoudness(blocks: []), -.infinity)
        XCTAssertEqual(LoudnessAnalyzer.gatedLoudness(blocks: [-80, -90]), -.infinity)
    }

    /// The relative gate exists so a quiet intro does not drag a record's number
    /// down. A long silence next to a loud passage must barely move it.
    func testTheRelativeGateIgnoresQuietPassages() {
        let loudOnly = LoudnessAnalyzer.gatedLoudness(blocks: Array(repeating: -12, count: 40))
        let withQuietIntro = LoudnessAnalyzer.gatedLoudness(
            blocks: Array(repeating: -60, count: 40) + Array(repeating: -12, count: 40)
        )
        XCTAssertEqual(loudOnly, withQuietIntro, accuracy: 0.01)
    }
}
