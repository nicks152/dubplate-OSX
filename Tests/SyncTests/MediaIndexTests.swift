import XCTest
import DubplateCore
@testable import DubplateSync

/// The transfer queue that has to survive a relaunch.
final class MediaIndexTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL.temporaryDirectory.appending(path: "DubplateIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func descriptor(uploaded: Bool = false) -> MediaDescriptor {
        MediaDescriptor(
            assetID: UUID(),
            kind: .audio,
            relativePath: "Audio/00/file.wav",
            originalFilename: "04 Midnight mix 5.wav",
            checksum: "abc",
            fileSize: 480_000_000,
            isUploaded: uploaded
        )
    }

    func testDescriptorsSurviveARelaunch() async throws {
        let first = MediaIndex(directory: directory)
        let entry = descriptor()
        await first.record(entry)

        let second = MediaIndex(directory: directory)
        let recovered = await second.descriptor(for: entry.assetID)
        XCTAssertEqual(recovered?.originalFilename, "04 Midnight mix 5.wav")
        XCTAssertEqual(recovered?.fileSize, 480_000_000)
    }

    /// An upload interrupted by a relaunch is still pending afterwards.
    func testPendingUploadsAreRemembered() async throws {
        let index = MediaIndex(directory: directory)
        let pending = descriptor()
        let done = descriptor(uploaded: true)
        await index.record([pending, done])

        let reopened = MediaIndex(directory: directory)
        let outstanding = await reopened.pendingUploads()
        XCTAssertEqual(outstanding.map(\.assetID), [pending.assetID])
    }

    func testMarkingUploaded() async throws {
        let index = MediaIndex(directory: directory)
        let entry = descriptor()
        await index.record(entry)
        await index.markUploaded(entry.assetID)
        XCTAssertTrue(await index.pendingUploads().isEmpty)
    }

    func testRemoving() async throws {
        let index = MediaIndex(directory: directory)
        let entry = descriptor()
        await index.record(entry)
        await index.remove(entry.assetID)
        XCTAssertNil(await index.descriptor(for: entry.assetID))
    }

    /// A corrupt index costs at most a re-upload; it must never stop the app.
    func testACorruptIndexStartsFresh() async throws {
        try Data("not json".utf8).write(to: directory.appending(path: "media-index.json"))
        let index = MediaIndex(directory: directory)
        XCTAssertTrue(await index.all().isEmpty)

        let entry = descriptor()
        await index.record(entry)
        XCTAssertEqual(await index.all().count, 1)
    }

    func testSyncStatusCopy() {
        XCTAssertFalse(SyncStatus.synced.isWorthMentioning)
        XCTAssertTrue(SyncStatus.downloading.isWorthMentioning)
        XCTAssertEqual(SyncStatus.availableOnOtherDevice.label, "Available on your Mac")
        XCTAssertNil(CloudAccountState.available.explanation)
        XCTAssertEqual(CloudAccountState.signedOut.explanation?.kind, .iCloudSignedOut)
    }
}
