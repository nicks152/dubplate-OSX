import XCTest
import SwiftData
@testable import DubplateCore

/// The library, exercised through the same calls the interface makes.
@MainActor
final class LibraryStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var store: LibraryStore!
    private var mediaRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        container = try DubplateSchema.container(.ephemeral)
        mediaRoot = URL.temporaryDirectory.appending(path: "DubplateTests-\(UUID().uuidString)")
        let mediaStore = MediaStore(root: mediaRoot)
        try mediaStore.prepare()
        store = LibraryStore(
            context: container.mainContext,
            mediaStore: mediaStore,
            inspector: StubAudioInspector()
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: mediaRoot)
        store = nil
        container = nil
        try await super.tearDown()
    }

    /// A file that is really on disk, so imports exercise the real copy path.
    private func makeAudioFile(named name: String, bytes: Int = 2_048) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "DubplateBounces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data(repeating: UInt8.random(in: 0...255), count: bytes).write(to: url)
        return url
    }

    func testCreatingARelease() throws {
        let release = store.createRelease(title: "NO SIGNAL", artistName: "Nick Loder", type: .album)
        XCTAssertEqual(store.releases().count, 1)
        XCTAssertEqual(release.releaseType, .album)
        XCTAssertEqual(release.trackCount, 0)
        XCTAssertEqual(release.subtitleLine, "Album · 0 tracks")
    }

    func testImportingBouncesSequencesThem() async throws {
        let release = store.createRelease(title: "NO SIGNAL", artistName: "Nick Loder", type: .album)
        let urls = try ["02 Dust.wav", "01 Intro.wav", "03 Midnight.wav"].map { try makeAudioFile(named: $0) }

        let plan = await store.plan(for: urls, in: release)
        let outcome = await store.apply(plan, to: release)

        XCTAssertEqual(outcome.createdTracks.count, 3)
        XCTAssertEqual(release.orderedTracks.map(\.displayTitle), ["Intro", "Dust", "Midnight"])
        XCTAssertEqual(release.orderedTracks.map(\.trackNumber), [1, 2, 3])
        XCTAssertEqual(release.trackOrder.count, 3)
        XCTAssertTrue(release.orderedTracks.allSatisfy { $0.currentVersion != nil })
    }

    func testReorderingRewritesTheSequence() async throws {
        let release = store.createRelease(title: "EP", artistName: "A", type: .ep)
        let urls = try ["01 A.wav", "02 B.wav", "03 C.wav"].map { try makeAudioFile(named: $0) }
        await store.apply(await store.plan(for: urls, in: release), to: release)

        store.move(in: release, fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(release.orderedTracks.map(\.displayTitle), ["C", "A", "B"])
        XCTAssertEqual(release.orderedTracks.map(\.trackNumber), [1, 2, 3])
    }

    func testDroppingABounceOnATrackAddsAVersionAndMakesItCurrent() async throws {
        let release = store.createRelease(title: "Single", artistName: "A", type: .single)
        await store.apply(await store.plan(for: [try makeAudioFile(named: "Midnight mix 1.wav")], in: release), to: release)
        let track = try XCTUnwrap(release.orderedTracks.first)
        let firstVersion = try XCTUnwrap(track.currentVersion)

        let replacement = try makeAudioFile(named: "Midnight mix 2.wav")
        await store.apply(choice: .addAsNewVersion, url: replacement, to: track)

        XCTAssertEqual(track.versionCount, 2)
        XCTAssertNotEqual(track.currentVersionID, firstVersion.id)
        XCTAssertEqual(track.currentVersion?.versionNumber, 2)
        XCTAssertEqual(track.currentVersion?.label, "Mix 2")
    }

    func testReplacingCurrentVersionRemovesTheOldOne() async throws {
        let release = store.createRelease(title: "Single", artistName: "A", type: .single)
        await store.apply(await store.plan(for: [try makeAudioFile(named: "Midnight mix 1.wav")], in: release), to: release)
        let track = try XCTUnwrap(release.orderedTracks.first)

        await store.apply(choice: .replaceCurrentVersion, url: try makeAudioFile(named: "Midnight mix 2.wav"), to: track)

        XCTAssertEqual(track.versionCount, 1)
        XCTAssertEqual(track.currentVersion?.label, "Mix 2")
    }

    /// Deleting the mix that is playing must leave something to play.
    func testDeletingTheCurrentVersionPromotesTheNewestRemaining() async throws {
        let release = store.createRelease(title: "Single", artistName: "A", type: .single)
        await store.apply(await store.plan(for: [try makeAudioFile(named: "Midnight mix 1.wav")], in: release), to: release)
        let track = try XCTUnwrap(release.orderedTracks.first)
        await store.apply(choice: .addAsNewVersion, url: try makeAudioFile(named: "Midnight mix 2.wav"), to: track)
        let current = try XCTUnwrap(track.currentVersion)

        store.delete(version: current)

        XCTAssertEqual(track.versionCount, 1)
        XCTAssertNotNil(track.currentVersion)
        XCTAssertEqual(track.currentVersion?.versionNumber, 1)
    }

    /// The same file dropped twice is one file.
    func testReimportingTheSameFileIsRecognised() async throws {
        let release = store.createRelease(title: "Single", artistName: "A", type: .single)
        let url = try makeAudioFile(named: "Midnight.wav")
        await store.apply(await store.plan(for: [url], in: release), to: release)
        let outcome = await store.apply(await store.plan(for: [url], in: release), to: release)

        XCTAssertEqual(outcome.duplicateFilenames, ["Midnight.wav"])
        XCTAssertEqual(release.trackCount, 1)
    }

    func testImportingWithoutAReleaseFillsTheInbox() async throws {
        let url = try makeAudioFile(named: "Drums idea.wav")
        await store.apply(await store.plan(for: [url], in: nil), to: nil)

        XCTAssertEqual(store.inboxTracks().count, 1)
        XCTAssertEqual(store.inboxTracks().first?.displayTitle, "Drums idea")
        XCTAssertTrue(store.releases().isEmpty)
    }

    func testMovingAnInboxTrackOntoARelease() async throws {
        await store.apply(await store.plan(for: [try makeAudioFile(named: "Idea.wav")], in: nil), to: nil)
        let track = try XCTUnwrap(store.inboxTracks().first)
        let release = store.createRelease(title: "EP", artistName: "A", type: .ep)

        store.move(track: track, to: release)

        XCTAssertTrue(store.inboxTracks().isEmpty)
        XCTAssertEqual(release.orderedTracks.map(\.id), [track.id])
        XCTAssertEqual(track.trackNumber, 1)
    }

    /// The same master can appear on a single and on the album. It used to be
    /// refused outright, which is indistinguishable from data loss.
    func testTheSameMasterCanAppearOnTwoReleases() async throws {
        let url = try makeAudioFile(named: "Midnight.wav")
        let single = store.createRelease(title: "Midnight", artistName: "A", type: .single)
        await store.apply(await store.plan(for: [url], in: single), to: single)

        let album = store.createRelease(title: "NO SIGNAL", artistName: "A", type: .album)
        let outcome = await store.apply(await store.plan(for: [url], in: album), to: album)

        XCTAssertEqual(outcome.createdTracks.count, 1)
        XCTAssertEqual(album.trackCount, 1)
        XCTAssertTrue(outcome.duplicateFilenames.isEmpty)

        // One file behind both, not two copies of the bytes.
        let singleAsset = try XCTUnwrap(single.orderedTracks.first?.currentAsset)
        let albumAsset = try XCTUnwrap(album.orderedTracks.first?.currentAsset)
        XCTAssertEqual(singleAsset.id, albumAsset.id)
        XCTAssertEqual(singleAsset.versions?.count, 2)
    }

    /// Deleting one of the two records must not silence the other.
    func testDeletingOneReleaseKeepsMediaSharedWithAnother() async throws {
        let url = try makeAudioFile(named: "Midnight.wav")
        let single = store.createRelease(title: "Midnight", artistName: "A", type: .single)
        await store.apply(await store.plan(for: [url], in: single), to: single)
        let album = store.createRelease(title: "NO SIGNAL", artistName: "A", type: .album)
        await store.apply(await store.plan(for: [url], in: album), to: album)
        let path = try XCTUnwrap(album.orderedTracks.first?.currentAsset?.relativePath)

        store.delete(release: single)

        XCTAssertTrue(store.mediaStore.exists(relativePath: path))
        XCTAssertNotNil(album.orderedTracks.first?.currentAsset)
    }

    /// The error copy promises "drop the bounce in again to restore it", so it has
    /// to actually restore it.
    func testRedroppingABounceRestoresAMissingFile() async throws {
        let release = store.createRelease(title: "Single", artistName: "A", type: .single)
        let url = try makeAudioFile(named: "Midnight.wav")
        await store.apply(await store.plan(for: [url], in: release), to: release)
        let asset = try XCTUnwrap(release.orderedTracks.first?.currentAsset)
        try store.mediaStore.remove(relativePath: asset.relativePath)
        XCTAssertFalse(store.mediaStore.exists(relativePath: asset.relativePath))

        let outcome = await store.apply(await store.plan(for: [url], in: release), to: release)

        XCTAssertEqual(outcome.repairedFilenames, ["Midnight.wav"])
        XCTAssertTrue(store.mediaStore.exists(relativePath: asset.relativePath))
        XCTAssertEqual(release.trackCount, 1, "a repair is not a new track")
    }

    /// An instrumental sits next to the vocal. It never replaces it.
    func testAVariantIsAddedButDoesNotBecomeCurrent() async throws {
        let release = store.createRelease(title: "Single", artistName: "A", type: .single)
        await store.apply(await store.plan(for: [try makeAudioFile(named: "Midnight mix 5.wav")], in: release), to: release)
        let track = try XCTUnwrap(release.orderedTracks.first)
        let vocal = try XCTUnwrap(track.currentVersion)

        await store.apply(
            choice: .addAsNewVersion,
            url: try makeAudioFile(named: "Midnight instrumental.wav"),
            to: track
        )

        XCTAssertEqual(track.versionCount, 2)
        XCTAssertEqual(track.currentVersionID, vocal.id, "the vocal is still the mix")
    }

    /// Availability is answered by looking, not by a synced flag.
    func testAvailabilityFollowsTheFileSystem() async throws {
        let release = store.createRelease(title: "Single", artistName: "A", type: .single)
        await store.apply(await store.plan(for: [try makeAudioFile(named: "Midnight.wav")], in: release), to: release)
        let asset = try XCTUnwrap(release.orderedTracks.first?.currentAsset)

        MediaAvailability.refresh(release, using: store.mediaStore)
        XCTAssertEqual(asset.availability, .available)

        try store.mediaStore.remove(relativePath: asset.relativePath)
        MediaAvailability.refresh(release, using: store.mediaStore)
        XCTAssertEqual(asset.availability, .cloudOnly)
        XCTAssertFalse(asset.availability.isPlayableNow)
    }

    /// Taking a track off a record is not the same as destroying it.
    func testRemovingFromAReleaseKeepsEverything() async throws {
        let release = store.createRelease(title: "EP", artistName: "A", type: .ep)
        await store.apply(await store.plan(for: [try makeAudioFile(named: "01 A.wav")], in: release), to: release)
        let track = try XCTUnwrap(release.orderedTracks.first)
        let path = try XCTUnwrap(track.currentAsset?.relativePath)

        store.removeFromRelease(track: track)

        XCTAssertEqual(release.trackCount, 0)
        XCTAssertEqual(store.inboxTracks().map(\.id), [track.id])
        XCTAssertTrue(store.mediaStore.exists(relativePath: path))
    }

    func testDeletingAReleaseRemovesItsTracks() async throws {
        let release = store.createRelease(title: "Gone", artistName: "A", type: .album)
        await store.apply(await store.plan(for: [try makeAudioFile(named: "01 A.wav")], in: release), to: release)

        store.delete(release: release)

        XCTAssertTrue(store.releases().isEmpty)
        XCTAssertTrue(store.inboxTracks().isEmpty)
    }
}
