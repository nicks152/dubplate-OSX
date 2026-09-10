import XCTest
@testable import DubplateCore

/// What Dubplate is allowed to guess, and — more importantly — what it is not.
final class VersionMatcherTests: XCTestCase {

    private let midnight = TrackSummary(
        id: UUID(),
        title: "Midnight",
        trackNumber: 4,
        matchKeys: ["midnight"]
    )
    private let dust = TrackSummary(
        id: UUID(),
        title: "Dust",
        trackNumber: 2,
        matchKeys: ["dust"]
    )

    func testExactNameIsCertain() {
        let match = VersionMatcher.match(filename: "04 Midnight Mix 6.wav", among: [midnight, dust])
        XCTAssertEqual(match?.trackID, midnight.id)
        XCTAssertEqual(match?.confidence, 1)
        XCTAssertTrue(match?.isConfident == true)
    }

    func testRevisionMarkersStillMatch() {
        for filename in ["Midnight rough.wav", "Midnight new drums.wav", "Midnight master 2.wav"] {
            let match = VersionMatcher.match(filename: filename, among: [midnight, dust])
            XCTAssertEqual(match?.trackID, midnight.id, "\(filename) should match Midnight")
            XCTAssertTrue(match?.isConfident == true, "\(filename) should be confident")
        }
    }

    /// The rule that stops Dubplate turning two songs into one.
    func testAContainedNameWithRealWordsIsADifferentSong() {
        XCTAssertNil(VersionMatcher.match(filename: "Dust Storm.wav", among: [dust]))
        let untitled = TrackSummary(id: UUID(), title: "Untitled Two", trackNumber: 4, matchKeys: ["untitledtwo"])
        let match = VersionMatcher.match(filename: "04 Untitled.wav", among: [untitled])
        // Same slot on the record, so worth offering — but never confidently.
        XCTAssertEqual(match?.confidence, 0.75)
        XCTAssertFalse(match?.isConfident == true)
    }

    func testDifferentSongsDoNotMatch() {
        XCTAssertNil(VersionMatcher.match(filename: "After Dark.wav", among: [midnight, dust]))
        XCTAssertNil(VersionMatcher.match(filename: "Dusk.wav", among: [dust]))
        XCTAssertNil(VersionMatcher.match(filename: "Drums idea.wav", among: [midnight, dust]))
    }

    /// Jaro-Winkler is here so a typo in a filename still finds its song.
    func testTypoesStillMatch() {
        let match = VersionMatcher.match(filename: "Midnite v2.wav", among: [midnight])
        XCTAssertEqual(match?.trackID, midnight.id)
        XCTAssertTrue(match?.isConfident == true)
    }

    func testSimilarityOrdersSensibly() {
        XCTAssertEqual(VersionMatcher.similarity("midnight", "midnight"), 1)
        XCTAssertGreaterThan(
            VersionMatcher.similarity("midnight", "midnite"),
            VersionMatcher.similarity("midnight", "afterdark")
        )
        XCTAssertEqual(VersionMatcher.similarity("", "midnight"), 0)
    }

    func testAVersionsOwnFilenameIsAlsoAMatchKey() {
        let track = TrackSummary(
            id: UUID(),
            title: "Untitled",
            trackNumber: 7,
            matchKeys: ["untitled", "sundaysketch"]
        )
        let match = VersionMatcher.match(filename: "Sunday Sketch mix 3.wav", among: [track])
        XCTAssertEqual(match?.trackID, track.id)
    }
}
