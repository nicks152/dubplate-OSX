import XCTest
import DubplateCore
@testable import DubplateSync

/// What happens when two devices both edited the same record.
final class ConflictResolutionTests: XCTestCase {

    private func ids(_ count: Int) -> [String] {
        (0..<count).map { _ in UUID().uuidString }
    }

    /// The winning order decides sequence; the relationship decides membership.
    func testATrackAddedElsewhereIsNeverDropped() {
        let identifiers = ids(4)
        let staleOrder = Array(identifiers.prefix(3)).reversed().map { $0 }
        let present = identifiers

        let merged = TrackOrderMerge.reconcile(
            order: staleOrder,
            present: present,
            creationOrder: identifiers
        )

        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(Set(merged), Set(present))
        XCTAssertEqual(Array(merged.prefix(3)), staleOrder)
        XCTAssertEqual(merged.last, identifiers[3])
    }

    func testATrackDeletedElsewhereLeavesTheOrder() {
        let identifiers = ids(3)
        let merged = TrackOrderMerge.reconcile(
            order: identifiers,
            present: [identifiers[0], identifiers[2]],
            creationOrder: identifiers
        )
        XCTAssertEqual(merged, [identifiers[0], identifiers[2]])
    }

    func testDuplicatesInTheOrderAreCollapsed() {
        let identifiers = ids(2)
        let merged = TrackOrderMerge.reconcile(
            order: [identifiers[0], identifiers[0], identifiers[1]],
            present: identifiers,
            creationOrder: identifiers
        )
        XCTAssertEqual(merged, identifiers)
    }

    func testAConsistentOrderIsLeftAlone() {
        let identifiers = ids(5)
        XCTAssertFalse(TrackOrderMerge.needsReconciling(order: identifiers, present: identifiers))
        XCTAssertTrue(TrackOrderMerge.needsReconciling(order: Array(identifiers.dropLast()), present: identifiers))
    }

    /// Both bounces survive. That is the whole rule for media conflicts.
    func testCollidingVersionNumbersRenumberWithoutLosingAnything() {
        let now = Date()
        let older = VersionNumbering.Entry(id: UUID(), number: 6, createdAt: now)
        let newer = VersionNumbering.Entry(id: UUID(), number: 6, createdAt: now.addingTimeInterval(60))
        let untouched = VersionNumbering.Entry(id: UUID(), number: 5, createdAt: now)

        let assignments = VersionNumbering.resolveCollisions([newer, older, untouched])

        XCTAssertEqual(assignments.count, 1)
        XCTAssertEqual(assignments[newer.id], 7)
        XCTAssertNil(assignments[older.id], "the older bounce keeps the number people have been saying out loud")
        XCTAssertNil(assignments[untouched.id])
    }

    /// Both devices must reach the same answer without talking to each other.
    func testRenumberingIsDeterministicWhenTimestampsTie() {
        let now = Date()
        let first = VersionNumbering.Entry(id: UUID(), number: 3, createdAt: now)
        let second = VersionNumbering.Entry(id: UUID(), number: 3, createdAt: now)

        let one = VersionNumbering.resolveCollisions([first, second])
        let two = VersionNumbering.resolveCollisions([second, first])
        XCTAssertEqual(one, two)
    }

    func testNoCollisionMeansNoChanges() {
        let entries = (1...4).map {
            VersionNumbering.Entry(id: UUID(), number: $0, createdAt: Date())
        }
        XCTAssertTrue(VersionNumbering.resolveCollisions(entries).isEmpty)
        XCTAssertEqual(VersionNumbering.next(after: entries), 5)
    }

    func testThreeWayCollisionCascades() {
        let now = Date()
        let entries = (0..<3).map {
            VersionNumbering.Entry(id: UUID(), number: 2, createdAt: now.addingTimeInterval(Double($0)))
        }
        let assignments = VersionNumbering.resolveCollisions(entries)
        XCTAssertEqual(Set(assignments.values), [3, 4])
    }
}
