import XCTest
@testable import DubplateCore

/// The file layer: where audio goes, and what happens when it is interrupted.
final class MediaStoreTests: XCTestCase {

    private var root: URL!
    private var store: MediaStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL.temporaryDirectory.appending(path: "DubplateMediaTests-\(UUID().uuidString)")
        store = MediaStore(root: root)
        try store.prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeSource(named name: String, bytes: Int = 4_096) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "DubplateSource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    /// Paths are relative so they survive an iOS container being re-created.
    func testRelativePathsAreShardedAndPortable() {
        let id = UUID()
        let path = store.relativePath(area: .audio, assetID: id, fileExtension: "WAV")
        XCTAssertTrue(path.hasPrefix("Audio/"))
        XCTAssertTrue(path.hasSuffix(".wav"))
        XCTAssertTrue(path.contains(id.uuidString))
        XCTAssertFalse(path.hasPrefix("/"))

        let elsewhere = MediaStore(root: URL(filePath: "/somewhere/else"))
        XCTAssertEqual(
            elsewhere.url(forRelativePath: path).path(percentEncoded: false),
            "/somewhere/else/" + path
        )
    }

    func testIngestCopiesAndLeavesTheOriginalAlone() throws {
        let source = try makeSource(named: "Midnight.wav")
        let result = try store.ingest(contentsOf: source, area: .audio)

        XCTAssertTrue(store.exists(relativePath: result.relativePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        XCTAssertEqual(result.fileSize, 4_096)
    }

    func testChecksumRecognisesTheSameFileAndSeparatesDifferentOnes() throws {
        let source = try makeSource(named: "A.wav")
        let copy = try makeSource(named: "B.wav")
        let different = try makeSource(named: "C.wav", bytes: 8_192)

        XCTAssertEqual(try Checksum.signature(ofFileAt: source), try Checksum.signature(ofFileAt: copy))
        XCTAssertNotEqual(try Checksum.signature(ofFileAt: source), try Checksum.signature(ofFileAt: different))
    }

    /// A crash halfway through a copy must not leave something that looks valid.
    func testInterruptedImportsAreCleanedUp() throws {
        let staging = root.appending(path: "Audio/AB/.incoming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 1, 2]).write(to: staging)

        XCTAssertEqual(store.removeOrphanedStagingFiles(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
    }

    func testRemovingMediaIsIdempotent() throws {
        let source = try makeSource(named: "Gone.wav")
        let result = try store.ingest(contentsOf: source, area: .audio)

        try store.remove(relativePath: result.relativePath)
        XCTAssertFalse(store.exists(relativePath: result.relativePath))
        XCTAssertNoThrow(try store.remove(relativePath: result.relativePath))
    }

    func testUsedBytesCountsWhatIsThere() throws {
        XCTAssertEqual(store.usedBytes(), 0)
        _ = try store.ingest(contentsOf: try makeSource(named: "One.wav"), area: .audio)
        _ = try store.ingest(contentsOf: try makeSource(named: "Two.wav"), area: .audio)
        XCTAssertEqual(store.usedBytes(), 8_192)
    }

    func testEmptyRelativePathIsNeverConsideredPresent() {
        XCTAssertFalse(store.exists(relativePath: ""))
    }
}
