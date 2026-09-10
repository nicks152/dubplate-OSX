import XCTest
@testable import DubplateCore

/// What a drop does, decided before anything is written.
final class ImportPlannerTests: XCTestCase {

    private func candidates(_ names: [String], creationDates: [Date?] = []) -> [ImportCandidate] {
        names.enumerated().map { index, name in
            ImportCandidate(
                url: URL(filePath: "/Bounces/NO SIGNAL/\(name)"),
                dropIndex: index,
                fileSize: 1_024,
                creationDate: index < creationDates.count ? creationDates[index] : nil
            )
        }
    }

    func testNumberedBouncesBecomeASequence() {
        let plan = ImportPlanner.plan(
            candidates: candidates([
                "03 Something New.wav",
                "01 Intro.wav",
                "02 Dust.wav"
            ])
        )
        XCTAssertEqual(plan.orderingSignal, .filenameNumbers)
        XCTAssertEqual(plan.newTracks.map(\.title), ["Intro", "Dust", "Something New"])
        XCTAssertEqual(plan.newTracks.map(\.trackNumber), [1, 2, 3])
    }

    func testUnnumberedBouncesKeepTheDropOrder() {
        let plan = ImportPlanner.plan(candidates: candidates(["Dust.wav", "Intro.wav", "Midnight.wav"]))
        XCTAssertEqual(plan.orderingSignal, .dropOrder)
        XCTAssertEqual(plan.newTracks.map(\.title), ["Dust", "Intro", "Midnight"])
    }

    /// Several bounces of the same unknown song are one track with versions, not
    /// three tracks with the same name.
    func testRepeatedBouncesBecomeVersionsOfOneTrack() {
        let plan = ImportPlanner.plan(
            candidates: candidates(["Midnight Mix 1.wav", "Midnight Mix 3.wav", "Midnight Mix 2.wav"])
        )
        XCTAssertEqual(plan.newTracks.count, 1)
        XCTAssertEqual(plan.newTracks.first?.title, "Midnight")
        // Oldest first, so the newest bounce ends up current.
        XCTAssertEqual(
            plan.newTracks.first?.candidates.map(\.parsed.versionOrdinal),
            [1, 2, 3]
        )
    }

    func testBouncesOfExistingTracksBecomeVersions() {
        let existing = [
            TrackSummary(id: UUID(), title: "Midnight", trackNumber: 4, matchKeys: ["midnight"])
        ]
        let plan = ImportPlanner.plan(
            candidates: candidates(["04 Midnight Mix 6.wav", "After Dark.wav"]),
            existingTracks: existing,
            nextTrackNumber: 5
        )
        XCTAssertEqual(plan.newVersions.count, 1)
        XCTAssertEqual(plan.newVersions.first?.match.trackID, existing[0].id)
        XCTAssertEqual(plan.newTracks.map(\.title), ["After Dark"])
        XCTAssertEqual(plan.newTracks.first?.trackNumber, 5)
    }

    func testArtworkAndVideoAreSeparated() {
        let plan = ImportPlanner.plan(
            candidates: candidates(["01 Intro.wav", "cover.jpg", "loop.mov", "session.logicx"])
        )
        XCTAssertEqual(plan.artwork.count, 1)
        XCTAssertEqual(plan.motion.count, 1)
        XCTAssertEqual(plan.newTracks.count, 1)
        XCTAssertEqual(plan.rejected.map(\.filename), ["session.logicx"])
    }

    func testEmptyDropDoesNothing() {
        let plan = ImportPlanner.plan(candidates: [])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.audioFileCount, 0)
    }

    func testSummaryReadsLikeASentence() {
        let existing = [TrackSummary(id: UUID(), title: "Midnight", trackNumber: 4, matchKeys: ["midnight"])]
        let plan = ImportPlanner.plan(
            candidates: candidates(["Midnight Mix 6.wav", "After Dark.wav", "cover.png"]),
            existingTracks: existing
        )
        XCTAssertEqual(plan.summary, "1 track · 1 new version · cover")
    }

    /// Numbers that collide are not numbers worth trusting.
    func testDuplicateNumbersFallBackToFilenameOrder() {
        let plan = ImportPlanner.plan(candidates: candidates(["01 A.wav", "01 B.wav", "02 C.wav"]))
        XCTAssertNotEqual(plan.orderingSignal, .filenameNumbers)
    }

    func testVersionOrderingUsesCreationDateWhenThereIsNoNumber() {
        let now = Date()
        let items = candidates(
            ["Midnight rough.wav", "Midnight master.wav"],
            creationDates: [now, now.addingTimeInterval(-3600)]
        )
        let ordered = TrackOrdering.orderVersions(items)
        XCTAssertEqual(ordered.first?.filename, "Midnight master.wav")
    }
}
