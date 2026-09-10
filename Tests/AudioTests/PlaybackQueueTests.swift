import XCTest
import DubplateCore
@testable import DubplateAudio

/// Skipping, shuffling, repeating and running off the end — without an audio device.
final class PlaybackQueueTests: XCTestCase {

    private func item(_ index: Int, releaseID: UUID = UUID()) -> PlaybackQueueItem {
        PlaybackQueueItem(
            trackID: UUID(),
            versionID: UUID(),
            assetID: UUID(),
            relativePath: "Audio/00/track-\(index).wav",
            title: "Track \(index)",
            artistName: "Nick Loder",
            releaseTitle: "NO SIGNAL",
            releaseID: releaseID,
            trackNumber: index,
            duration: 200,
            format: AudioFormatDescription(sampleRate: 48_000, bitDepth: 24, channelCount: 2, codec: "WAV"),
            availability: .available
        )
    }

    private func makeQueue(_ count: Int) -> PlaybackQueue {
        let releaseID = UUID()
        return PlaybackQueue(items: (1...count).map { item($0, releaseID: releaseID) })
    }

    func testPlaysInOrder() {
        var queue = makeQueue(3)
        XCTAssertEqual(queue.current?.title, "Track 1")
        XCTAssertEqual(queue.next?.title, "Track 2")
        XCTAssertEqual(queue.upNext.map(\.title), ["Track 2", "Track 3"])
    }

    func testAdvancingStopsAtTheEnd() {
        var queue = makeQueue(2)
        XCTAssertTrue(queue.advance())
        XCTAssertEqual(queue.current?.title, "Track 2")
        XCTAssertFalse(queue.advance())
        XCTAssertEqual(queue.current?.title, "Track 2")
        XCTAssertNil(queue.next)
    }

    func testRepeatAllWrapsAround() {
        var queue = makeQueue(2)
        queue.setRepeatMode(.all)
        XCTAssertTrue(queue.advance())
        XCTAssertTrue(queue.advance())
        XCTAssertEqual(queue.current?.title, "Track 1")
        XCTAssertTrue(queue.goBack())
        XCTAssertEqual(queue.current?.title, "Track 2")
    }

    /// Repeat-one repeats on its own, but pressing next still moves on — which is
    /// what every player does and what hands expect.
    func testRepeatOneOnlyRepeatsWhenNobodyPressedAnything() {
        var queue = makeQueue(3)
        queue.setRepeatMode(.one)
        XCTAssertTrue(queue.advance())
        XCTAssertEqual(queue.current?.title, "Track 1")
        XCTAssertTrue(queue.advance(userInitiated: true))
        XCTAssertEqual(queue.current?.title, "Track 2")
    }

    func testGoingBackAtTheStartDoesNothing() {
        var queue = makeQueue(3)
        XCTAssertFalse(queue.goBack())
        XCTAssertEqual(queue.current?.title, "Track 1")
    }

    /// Turning shuffle on must not change what is playing.
    func testShuffleKeepsTheCurrentTrackInPlace() {
        var queue = makeQueue(12)
        _ = queue.advance()
        _ = queue.advance()
        let playing = queue.current?.id

        queue.setShuffled(true)

        XCTAssertEqual(queue.current?.id, playing)
        XCTAssertEqual(queue.upNext.count, 9)
        XCTAssertFalse(queue.upNext.contains { $0.id == playing })
    }

    func testUnshufflingRestoresTheSequence() {
        var queue = makeQueue(6)
        queue.setShuffled(true)
        queue.setShuffled(false)
        XCTAssertEqual(queue.upNext.map(\.title), ["Track 2", "Track 3", "Track 4", "Track 5", "Track 6"])
    }

    func testJumpingToATrack() {
        var queue = makeQueue(5)
        let target = queue.items[3]
        queue.jump(toItemWithID: target.id)
        XCTAssertEqual(queue.current?.id, target.id)
        XCTAssertEqual(queue.upNext.map(\.title), ["Track 5"])
    }

    /// Switching version replaces the entry in place: the record does not reorder
    /// itself because someone chose a different mix.
    func testReplacingAnItemKeepsItsPosition() {
        var queue = makeQueue(3)
        _ = queue.advance()
        let existing = try? XCTUnwrap(queue.current)
        guard let existing else { return XCTFail("no current item") }

        var replacement = item(99)
        replacement = PlaybackQueueItem(
            id: replacement.id,
            trackID: existing.trackID,
            versionID: UUID(),
            assetID: UUID(),
            relativePath: "Audio/00/other.wav",
            title: existing.title,
            artistName: existing.artistName,
            releaseTitle: existing.releaseTitle,
            releaseID: existing.releaseID,
            trackNumber: existing.trackNumber,
            duration: existing.duration,
            format: existing.format,
            availability: .available
        )
        queue.replace(itemWithID: existing.id, with: replacement)
        queue.jump(toItemWithID: replacement.id)

        XCTAssertEqual(queue.items.count, 3)
        XCTAssertEqual(queue.current?.relativePath, "Audio/00/other.wav")
        XCTAssertEqual(queue.upNext.map(\.title), ["Track 3"])
    }

    func testPlayNextInsertsRightAfterTheCurrentTrack() {
        var queue = makeQueue(3)
        let inserted = item(42)
        queue.playNext(inserted)
        XCTAssertEqual(queue.upNext.first?.id, inserted.id)
        XCTAssertEqual(queue.upNext.count, 3)
    }

    func testEmptyQueueIsHarmless() {
        var queue = PlaybackQueue()
        XCTAssertNil(queue.current)
        XCTAssertNil(queue.next)
        XCTAssertFalse(queue.advance())
        XCTAssertFalse(queue.goBack())
        XCTAssertTrue(queue.upNext.isEmpty)
        queue.jump(to: 4)
        XCTAssertNil(queue.current)
    }

    func testUnplayableItemsAreFlagged() {
        let missing = PlaybackQueueItem(
            trackID: UUID(), versionID: UUID(), assetID: UUID(), relativePath: "",
            title: "Gone", artistName: "A", releaseTitle: "R", releaseID: UUID(),
            trackNumber: 1, duration: 0, format: .unknown, availability: .cloudOnly
        )
        XCTAssertFalse(missing.isPlayable)
    }
}
