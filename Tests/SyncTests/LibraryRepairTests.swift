import XCTest
import SwiftData
import DubplateCore
@testable import DubplateSync

/// Putting a release back together after a merge.
@MainActor
final class LibraryRepairTests: XCTestCase {

    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        context = try DubplateSchema.container(.ephemeral).mainContext
    }

    private func makeRelease(trackCount: Int) -> Release {
        let release = Release(title: "NO SIGNAL", artistName: "A", releaseType: .album)
        context.insert(release)
        for index in 0..<trackCount {
            let track = Track(
                title: "Track \(index + 1)",
                trackNumber: index + 1,
                createdAt: Date().addingTimeInterval(Double(index))
            )
            context.insert(track)
            track.release = release
            release.trackOrder.append(track.id.uuidString)
        }
        return release
    }

    func testAConsistentReleaseIsNotTouched() {
        let release = makeRelease(trackCount: 4)
        let before = release.updatedAt
        XCTAssertFalse(LibraryRepair.repair(release, in: context))
        XCTAssertEqual(release.updatedAt, before, "a needless write would sync straight back out again")
    }

    func testMissingOrderEntriesAreRestored() {
        let release = makeRelease(trackCount: 3)
        release.trackOrder.removeLast()

        XCTAssertTrue(LibraryRepair.repair(release, in: context))
        XCTAssertEqual(release.trackOrder.count, 3)
        XCTAssertEqual(release.orderedTracks.map(\.trackNumber), [1, 2, 3])
    }

    func testTrackNumbersFollowTheSequence() {
        let release = makeRelease(trackCount: 3)
        release.trackOrder.reverse()

        XCTAssertTrue(LibraryRepair.repair(release, in: context))
        XCTAssertEqual(release.orderedTracks.map(\.title), ["Track 3", "Track 2", "Track 1"])
        XCTAssertEqual(release.orderedTracks.map(\.trackNumber), [1, 2, 3])
    }

    func testADanglingCurrentVersionHeals() {
        let release = makeRelease(trackCount: 1)
        let track = release.orderedTracks[0]
        for number in 1...2 {
            let version = TrackVersion(versionNumber: number)
            context.insert(version)
            version.track = track
        }
        track.currentVersionID = UUID()

        XCTAssertTrue(LibraryRepair.repair(release, in: context))
        XCTAssertEqual(track.currentVersion?.versionNumber, 2)
    }

    func testConcurrentVersionsBothSurviveAndAreRenumbered() {
        let release = makeRelease(trackCount: 1)
        let track = release.orderedTracks[0]
        let now = Date()
        for offset in 0..<2 {
            let version = TrackVersion(
                versionNumber: 6,
                label: "Mix 6 (\(offset))",
                createdAt: now.addingTimeInterval(Double(offset))
            )
            context.insert(version)
            version.track = track
        }
        track.currentVersionID = track.versions?.first?.id

        XCTAssertTrue(LibraryRepair.repair(release, in: context))
        XCTAssertEqual(track.versionCount, 2, "no bounce is ever deleted to resolve a conflict")
        XCTAssertEqual(Set(track.orderedVersions.map(\.versionNumber)), [6, 7])
    }

    func testATrackWithNoVersionsClearsItsPointer() {
        let release = makeRelease(trackCount: 1)
        let track = release.orderedTracks[0]
        track.currentVersionID = UUID()

        XCTAssertTrue(LibraryRepair.repair(release, in: context))
        XCTAssertNil(track.currentVersionID)
    }

    func testRepairIsIdempotent() {
        let release = makeRelease(trackCount: 5)
        release.trackOrder.removeFirst()
        XCTAssertTrue(LibraryRepair.repair(release, in: context))
        XCTAssertFalse(LibraryRepair.repair(release, in: context))
    }
}
