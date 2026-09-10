import XCTest
@testable import DubplateCore

/// The filename rules, stated as the cases they were designed against.
///
/// Every expectation here is a real bounce name of the kind that comes out of Logic,
/// Pro Tools and Ableton. When a rule changes, this file is where the argument
/// about whether it should have is settled.
final class FilenameParserTests: XCTestCase {

    private func check(
        _ filename: String,
        number: Int?,
        title: String,
        label: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parsed = FilenameParser.parse(filename)
        XCTAssertEqual(parsed.trackNumber, number, "track number for \(filename)", file: file, line: line)
        XCTAssertEqual(parsed.title, title, "title for \(filename)", file: file, line: line)
        XCTAssertEqual(parsed.versionLabel, label, "version label for \(filename)", file: file, line: line)
    }

    func testLeadingNumbers() {
        check("04 Midnight v5.wav", number: 4, title: "Midnight", label: "v5")
        check("01_intro.wav", number: 1, title: "Intro", label: nil)
        check("05 After Dark.aiff", number: 5, title: "After Dark", label: nil)
        check("A1 Untitled.wav", number: 1, title: "Untitled", label: nil)
    }

    func testVersionMarkers() {
        check("Midnight Mix 01.wav", number: nil, title: "Midnight", label: "Mix 1")
        check("Midnight Mix 02.wav", number: nil, title: "Midnight", label: "Mix 2")
        check("04 Midnight master.wav", number: 4, title: "Midnight", label: "Master")
        check("04 Midnight master2.wav", number: 4, title: "Midnight", label: "Master 2")
        check("Blue Room bounce 12.wav", number: nil, title: "Blue Room", label: "Bounce 12")
        check("midnight rough.wav", number: nil, title: "Midnight", label: "Rough")
    }

    /// "Mix 01" and "Mix 1" are the same marker and must read the same way.
    func testLeadingZeroesAreNormalised() {
        XCTAssertEqual(FilenameParser.parse("Dust mix 07.wav").versionLabel, "Mix 7")
        XCTAssertEqual(FilenameParser.parse("Dust mix 7.wav").versionLabel, "Mix 7")
    }

    /// A producer who typed FINAL in capitals meant it.
    func testShoutingIsPreserved() {
        check("Track 2 FINAL 7.wav", number: 2, title: "Track 2", label: "FINAL 7")
        XCTAssertEqual(FilenameParser.parse("NO SIGNAL.wav").title, "NO SIGNAL")
    }

    /// "new" only counts as a marker when it sits in front of one.
    func testModifierWordsNeedSomethingToModify() {
        check("Track 3 new master.wav", number: 3, title: "Track 3", label: "New Master")
        check("Midnight new drums.wav", number: nil, title: "Midnight", label: "New Drums")
        // Nothing was peeled here, so "Down" stays part of the title.
        check("Come Down.wav", number: nil, title: "Come Down", label: nil)
    }

    func testArtistAndNumberSegments() {
        check("NO SIGNAL - 02 - Dust.wav", number: 2, title: "Dust", label: nil)
        check(
            "NO SIGNAL - 03 - Something New (final master).wav",
            number: 3,
            title: "Something New",
            label: "Final Master"
        )
    }

    func testFeaturedArtists() {
        let parsed = FilenameParser.parse("Dust (feat. Someone) v3.wav")
        XCTAssertEqual(parsed.title, "Dust")
        XCTAssertEqual(parsed.featuredArtists, "Someone")
        XCTAssertEqual(parsed.versionLabel, "v3")
        XCTAssertEqual(parsed.matchKey, "dust")
    }

    /// A name made entirely of revision words is a title, not a pile of markers.
    func testANameIsNeverStrippedToNothing() {
        check("Drums idea.wav", number: nil, title: "Drums idea", label: nil)
        check("10.wav", number: nil, title: "10", label: nil)
    }

    func testMatchKeysIgnoreMarkers() {
        let keys = [
            "04 Midnight v5.wav",
            "Midnight Mix 01.wav",
            "midnight rough.wav",
            "04 Midnight master2.wav"
        ].map { FilenameParser.parse($0).matchKey }
        XCTAssertEqual(Set(keys), ["midnight"])
    }

    func testFileKinds() {
        XCTAssertTrue(FilenameParser.isAudio("Midnight.wav"))
        XCTAssertTrue(FilenameParser.isAudio("Midnight.FLAC"))
        XCTAssertTrue(FilenameParser.isImage("cover.HEIC"))
        XCTAssertTrue(FilenameParser.isVideo("loop.mov"))
        XCTAssertFalse(FilenameParser.isAudio("session.logicx"))
        XCTAssertFalse(FilenameParser.isAudio("notes"))
    }

    /// Instrument and mix descriptors are perfectly good song titles. Stripping
    /// them unconditionally turned "05 Bass.wav" into a nameless track five.
    func testDescriptorsAreOnlyMarkersWhenARealWordSurvives() {
        check("05 Bass.wav", number: 5, title: "Bass", label: nil)
        check("07 Instrumental.wav", number: 7, title: "Instrumental", label: nil)
        check("09 Clean.wav", number: 9, title: "Clean", label: nil)
        check("Midnight drums.wav", number: nil, title: "Midnight", label: "Drums")
        check("Midnight instrumental.wav", number: nil, title: "Midnight", label: "Instrumental")
    }

    /// An instrumental is a different rendering, not a newer mix, so it must never
    /// silently become the mix everyone hears.
    func testVariantsAreFlagged() {
        XCTAssertTrue(FilenameParser.parse("Midnight instrumental.wav").isVariant)
        XCTAssertTrue(FilenameParser.parse("Midnight (radio edit).wav").isVariant)
        XCTAssertFalse(FilenameParser.parse("Midnight mix 6.wav").isVariant)
        XCTAssertFalse(FilenameParser.parse("Midnight new drums.wav").isVariant)
    }

    /// "04 Midnight" names track four. "24 Hours" is a song.
    func testOnlyAPaddedNumberNamesATrackSlot() {
        check("24 Hours.wav", number: 24, title: "24 Hours", label: nil)
        check("7 Rings.wav", number: 7, title: "7 Rings", label: nil)
        check("04 Midnight.wav", number: 4, title: "Midnight", label: nil)
    }

    /// Names Dubplate has to survive rather than understand. None of these are
    /// good answers; all of them are answers, which is the requirement.
    func testAwkwardNames() {
        XCTAssertEqual(FilenameParser.parse("").title, "")
        XCTAssertEqual(FilenameParser.parse(".wav").title, "Wav")
        XCTAssertEqual(FilenameParser.parse("((((.wav").title, "(((")
        XCTAssertEqual(FilenameParser.parse("04   Midnight   v5.wav").title, "Midnight")
    }


    /// A record named with a symbol still has to have a match key, or two bounces
    /// of it arrive as two separate tracks.
    func testPictographTitlesKeepAMatchKey() {
        let one = FilenameParser.parse("🔥 mix 1.wav")
        let two = FilenameParser.parse("🔥 mix 2.wav")
        XCTAssertFalse(one.matchKey.isEmpty)
        XCTAssertEqual(one.matchKey, two.matchKey)
        XCTAssertEqual(FilenameParser.normalize("Dust — Storm!"), "duststorm")
        // Arithmetic and currency signs are still dropped, as they always were.
        XCTAssertEqual(FilenameParser.normalize("A + B"), "ab")
    }
}
