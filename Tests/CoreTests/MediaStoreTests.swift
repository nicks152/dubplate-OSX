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

    // MARK: - Folder drops

    /// "Drop a folder of bounces here" is the first instruction the product gives.
    func testDroppingAFolderFindsTheFilesInside() throws {
        let folder = URL.temporaryDirectory.appending(path: "NO SIGNAL-\(UUID().uuidString)")
        let inner = folder.appending(path: "Bounces")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for name in ["02 Dust.wav", "01 Intro.wav", "cover.jpg", "notes.txt"] {
            try Data([0, 1]).write(to: inner.appending(path: name))
        }
        defer { try? FileManager.default.removeItem(at: folder) }

        let found = DroppedFiles.expand([folder]).map(\.lastPathComponent)

        XCTAssertEqual(found, ["01 Intro.wav", "02 Dust.wav", "cover.jpg"])
        XCTAssertFalse(found.contains("notes.txt"))
    }

    /// A Logic project is a directory on disk and emphatically not eight tracks.
    func testPackagesAreNotWalkedInto() throws {
        let project = URL.temporaryDirectory.appending(path: "Session-\(UUID().uuidString).logicx")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data([0]).write(to: project.appending(path: "audio.wav"))
        defer { try? FileManager.default.removeItem(at: project) }

        XCTAssertTrue(DroppedFiles.expand([project]).isEmpty)
    }


    /// A drop that hits the limit has to say so. Importing 2 of 5 in silence is
    /// indistinguishable from losing the other three.
    func testTruncatedDropReportsItself() throws {
        let folder = URL.temporaryDirectory.appending(path: "Drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 1...5 {
            try Data([0, 1]).write(to: folder.appending(path: "0\(index) Take.wav"))
        }
        defer { try? FileManager.default.removeItem(at: folder) }

        let full = DroppedFiles.expanded([folder])
        XCTAssertEqual(full.files.count, 5)
        XCTAssertFalse(full.wasTruncated)

        let clipped = DroppedFiles.expanded([folder], limit: 2)
        XCTAssertEqual(clipped.files.count, 2)
        XCTAssertTrue(clipped.wasTruncated)
    }

    /// Bytes an interrupted import left behind are swept; anything an asset still
    /// refers to, and anything whose name is not an asset identifier, is not.
    func testUnreferencedMediaIsSweptAndTheRestIsNot() throws {
        let root = URL.temporaryDirectory.appending(path: "Sweep-\(UUID().uuidString)")
        let store = MediaStore(root: root)
        try store.prepare()
        defer { try? FileManager.default.removeItem(at: root) }

        let kept = UUID()
        let orphan = UUID()
        let keptPath = store.relativePath(area: .audio, assetID: kept, fileExtension: "wav")
        let orphanPath = store.relativePath(area: .audio, assetID: orphan, fileExtension: "wav")
        for path in [keptPath, orphanPath] {
            let url = store.url(forRelativePath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0, 1]).write(to: url)
        }
        let stranger = root.appending(path: "Audio/notes.txt")
        try Data([0]).write(to: stranger)

        XCTAssertEqual(store.removeMedia(notReferencedBy: [kept]), 1)
        XCTAssertTrue(store.exists(relativePath: keptPath))
        XCTAssertFalse(store.exists(relativePath: orphanPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path(percentEncoded: false)))
    }
}
