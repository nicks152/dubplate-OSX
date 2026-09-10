import XCTest
@testable import DubplateAudio

/// Peak storage: one byte per bucket, and readable back.
final class WaveformTests: XCTestCase {

    func testHeightsAreNormalised() {
        let data = Data([0, 64, 128, 255])
        let heights = WaveformGenerator.heights(from: data)
        XCTAssertEqual(heights.count, 4)
        XCTAssertEqual(heights.first, 0)
        XCTAssertEqual(heights.last, 1, accuracy: 0.001)
        XCTAssertTrue(heights.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testEmptyDataIsEmpty() {
        XCTAssertTrue(WaveformGenerator.heights(from: Data()).isEmpty)
    }

    /// 400 buckets is 400 bytes, which is why they can live next to the asset.
    func testStorageIsSmall() {
        XCTAssertEqual(WaveformGenerator.defaultBucketCount, 400)
        let data = Data(repeating: 128, count: WaveformGenerator.defaultBucketCount)
        XCTAssertLessThan(data.count, 1_024)
    }
}
