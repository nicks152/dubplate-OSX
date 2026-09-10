import XCTest
import SwiftData
@testable import DubplateCore

/// The model rules that everything else depends on.
@MainActor
final class ModelTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        try DubplateSchema.container(.ephemeral).mainContext
    }

    func testOrderedTracksFollowsTrackOrder() throws {
        let context = try makeContext()
        let release = Release(title: "NO SIGNAL", artistName: "A", releaseType: .album)
        context.insert(release)

        let tracks = ["Intro", "Dust", "Midnight"].enumerated().map { index, title -> Track in
            let track = Track(title: title, trackNumber: index + 1, createdAt: Date().addingTimeInterval(Double(index)))
            context.insert(track)
            track.release = release
            return track
        }
        release.trackOrder = [tracks[2], tracks[0], tracks[1]].map(\.id.uuidString)

        XCTAssertEqual(release.orderedTracks.map(\.title), ["Midnight", "Intro", "Dust"])
    }

    /// A track that arrived from another device after the order was written must
    /// still appear, at the end, rather than vanishing.
    func testTracksMissingFromTheOrderAreStillListed() throws {
        let context = try makeContext()
        let release = Release(title: "EP", artistName: "A", releaseType: .ep)
        context.insert(release)

        let known = Track(title: "Known", createdAt: Date())
        let arrived = Track(title: "Arrived", createdAt: Date().addingTimeInterval(60))
        context.insert(known)
        context.insert(arrived)
        known.release = release
        arrived.release = release
        release.trackOrder = [known.id.uuidString]

        XCTAssertEqual(release.orderedTracks.map(\.title), ["Known", "Arrived"])
    }

    func testApplyOrderRenumbers() throws {
        let context = try makeContext()
        let release = Release(title: "EP", artistName: "A", releaseType: .ep)
        context.insert(release)
        let tracks = (1...3).map { index -> Track in
            let track = Track(title: "T\(index)", trackNumber: index)
            context.insert(track)
            track.release = release
            return track
        }
        release.applyOrder(tracks.reversed())

        XCTAssertEqual(release.orderedTracks.map(\.title), ["T3", "T2", "T1"])
        XCTAssertEqual(release.orderedTracks.map(\.trackNumber), [1, 2, 3])
    }

    /// `currentVersionID` is the only authority, and it heals itself.
    func testCurrentVersionFallsBackToTheNewest() throws {
        let context = try makeContext()
        let track = Track(title: "Midnight")
        context.insert(track)
        let versions = (1...3).map { number -> TrackVersion in
            let version = TrackVersion(versionNumber: number, label: "Mix \(number)")
            context.insert(version)
            version.track = track
            return version
        }
        track.currentVersionID = versions[1].id
        XCTAssertEqual(track.currentVersion?.versionNumber, 2)
        XCTAssertTrue(versions[1].isCurrent)

        // A version deleted on another device leaves a dangling identifier.
        track.currentVersionID = UUID()
        XCTAssertEqual(track.currentVersion?.versionNumber, 3)
    }

    func testNextVersionNumberNeverReusesANumber() throws {
        let context = try makeContext()
        let track = Track(title: "Midnight")
        context.insert(track)
        for number in [1, 2, 5] {
            let version = TrackVersion(versionNumber: number)
            context.insert(version)
            version.track = track
        }
        XCTAssertEqual(track.nextVersionNumber, 6)
    }

    func testDisplayTitleFallsBackToTheFilename() throws {
        let context = try makeContext()
        let track = Track(title: "")
        context.insert(track)
        let asset = AudioAsset(originalFilename: "Untitled sketch.wav")
        context.insert(asset)
        let version = TrackVersion(versionNumber: 1, audioAsset: asset)
        context.insert(version)
        version.track = track
        track.makeCurrent(version)

        XCTAssertEqual(track.displayTitle, "Untitled sketch.wav")
    }

    func testReleaseTypeInference() {
        XCTAssertEqual(ReleaseType.inferred(fromTrackCount: 1), .single)
        XCTAssertEqual(ReleaseType.inferred(fromTrackCount: 4), .ep)
        XCTAssertEqual(ReleaseType.inferred(fromTrackCount: 10), .album)
    }

    func testAvailabilityCopy() {
        XCTAssertNil(AvailabilityState.available.listenerExplanation)
        XCTAssertNil(AvailabilityState.local.listenerExplanation)
        XCTAssertEqual(
            AvailabilityState.cloudOnly.listenerExplanation,
            AvailabilityState.elsewhereDescription
        )
        XCTAssertFalse(AvailabilityState.missing.isPlayableNow)
    }

    /// The sample library is what previews, screenshots and the QA journey use.
    func testSampleLibraryIsCoherent() throws {
        let context = try makeContext()
        let releases = SampleLibrary.populate(context)

        XCTAssertEqual(releases.count, 3)
        for release in releases {
            XCTAssertFalse(release.orderedTracks.isEmpty)
            XCTAssertEqual(release.trackOrder.count, release.trackCount)
            for track in release.orderedTracks {
                XCTAssertNotNil(track.currentVersion, "\(track.title) has no current version")
                XCTAssertGreaterThan(track.duration, 0)
            }
        }
        XCTAssertEqual(releases.first { $0.title == "Midnight" }?.orderedTracks.first?.versionCount, 4)
    }

    func testFormatting() {
        XCTAssertEqual(Formatting.duration(222), "3:42")
        XCTAssertEqual(Formatting.duration(3_851), "1:04:11")
        XCTAssertEqual(Formatting.duration(-1), "--:--")
        XCTAssertEqual(Formatting.duration(.nan), "--:--")
        XCTAssertEqual(Formatting.longDuration(2_520), "42 minutes")
        XCTAssertEqual(Formatting.longDuration(4_440), "1 hour 14 minutes")
    }

    func testAudioFormatSummaries() {
        let format = AudioFormatDescription(sampleRate: 48_000, bitDepth: 24, channelCount: 2, codec: "WAV")
        XCTAssertEqual(format.summary, "24-bit · 48 kHz · Stereo")
        XCTAssertEqual(format.compactSummary, "24-bit / 48 kHz")
        XCTAssertEqual(
            AudioFormatDescription(sampleRate: 44_100, bitDepth: 16, channelCount: 1, codec: "AIFF").summary,
            "16-bit · 44.1 kHz · Mono"
        )
        XCTAssertTrue(format.isGaplessCompatible(with: format))
        XCTAssertFalse(
            format.isGaplessCompatible(with: AudioFormatDescription(sampleRate: 96_000, bitDepth: 24, channelCount: 2, codec: "WAV"))
        )
    }


    /// `isCurrent` has to agree with `currentVersion`, which heals itself when the
    /// identifier points at a version another device deleted. When they disagreed,
    /// the newest mix was listed as current *and* as previous.
    func testIsCurrentAgreesWithTheHealedCurrentVersion() {
        let track = Track(title: "Midnight")
        let first = TrackVersion(versionNumber: 1)
        let second = TrackVersion(versionNumber: 2)
        first.track = track
        second.track = track
        track.versions = [first, second]
        track.currentVersionID = nil

        XCTAssertEqual(track.currentVersion?.id, second.id)
        XCTAssertTrue(second.isCurrent)
        XCTAssertFalse(first.isCurrent)

        track.makeCurrent(first)
        XCTAssertTrue(first.isCurrent)
        XCTAssertFalse(second.isCurrent)
    }

    /// Nobody having looked yet is not the same as the file being here. The
    /// commonest way to reach it is a catalogue that arrived from iCloud without
    /// its audio.
    func testUninspectedAudioIsNotClaimedToBeHere() {
        let asset = AudioAsset(filename: "a.wav", relativePath: "Audio/00/a.wav")
        asset.localPresence = nil
        XCTAssertEqual(asset.availability, .cloudOnly)

        asset.localPresence = true
        XCTAssertEqual(asset.availability, .available)

        asset.transferState = .downloading
        XCTAssertEqual(asset.availability, .downloading)
    }

    /// The running order is reordered by `moveElements`, which stands in for
    /// SwiftUI's `move(fromOffsets:toOffset:)` because the model layer imports no
    /// UI framework. It has to behave identically, including the part everyone gets
    /// wrong: `toOffset` is an index in the *original* array.
    func testMoveElementsMatchesSwiftUISemantics() {
        func moved(_ items: [String], _ offsets: IndexSet, _ destination: Int) -> [String] {
            var copy = items
            copy.moveElements(fromOffsets: offsets, toOffset: destination)
            return copy
        }
        let items = ["A", "B", "C", "D"]

        XCTAssertEqual(moved(items, IndexSet([0]), 2), ["B", "A", "C", "D"])
        XCTAssertEqual(moved(items, IndexSet([3]), 0), ["D", "A", "B", "C"])
        XCTAssertEqual(moved(items, IndexSet([0, 1]), 4), ["C", "D", "A", "B"])
        XCTAssertEqual(moved(items, IndexSet([0]), 4), ["B", "C", "D", "A"])
        XCTAssertEqual(moved(["A", "B", "C", "D", "E"], IndexSet([1, 3]), 0),
                       ["B", "D", "A", "C", "E"])

        // Dropping a row on itself is not a change.
        XCTAssertEqual(moved(items, IndexSet([2]), 2), items)
        XCTAssertEqual(moved(items, IndexSet([1]), 1), items)

        // Nonsense in, the array back out.
        XCTAssertEqual(moved(items, IndexSet(), 2), items)
        XCTAssertEqual(moved(items, IndexSet([9]), 0), items)
    }
}
