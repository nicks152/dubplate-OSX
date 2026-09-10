import Foundation
import SwiftData

/// The three records used by previews, screenshots and tests.
///
/// Titles and track names are invented for Dubplate. No commercial music, artwork
/// or metadata is used anywhere in this repository.
public enum SampleLibrary {

    public struct Blueprint: Sendable {
        public let title: String
        public let artist: String
        public let type: ReleaseType
        public let year: Int
        public let trackTitles: [String]
        /// Extra bounces per track index, to exercise version switching.
        public let extraVersions: [Int: [String]]

        public init(
            title: String,
            artist: String,
            type: ReleaseType,
            year: Int,
            trackTitles: [String],
            extraVersions: [Int: [String]] = [:]
        ) {
            self.title = title
            self.artist = artist
            self.type = type
            self.year = year
            self.trackTitles = trackTitles
            self.extraVersions = extraVersions
        }
    }

    public static let noSignal = Blueprint(
        title: "NO SIGNAL",
        artist: "Nick Loder",
        type: .album,
        year: 2026,
        trackTitles: [
            "Intro", "Dust", "Something New", "Untitled", "After Dark",
            "Midnight", "Low Ceiling", "Hold", "Static", "No Signal"
        ],
        extraVersions: [5: ["Mix 4", "Mix 3"], 1: ["Rough"]]
    )

    public static let blueRoom = Blueprint(
        title: "BLUE ROOM",
        artist: "Nick Loder",
        type: .ep,
        year: 2026,
        trackTitles: ["Blue Room", "Second Floor", "Curtains", "Leave The Light"]
    )

    public static let midnight = Blueprint(
        title: "Midnight",
        artist: "Nick Loder",
        type: .single,
        year: 2026,
        trackTitles: ["Midnight"],
        extraVersions: [0: ["Mix 4", "Mix 3", "Rough"]]
    )

    public static let all: [Blueprint] = [noSignal, blueRoom, midnight]

    /// Fills a context with the sample library. Audio assets describe plausible
    /// files but point at nothing, so previews never touch disk.
    @discardableResult
    public static func populate(
        _ context: ModelContext,
        blueprints: [Blueprint] = all,
        availability: AvailabilityState = .available
    ) -> [Release] {
        var created: [Release] = []
        let now = Date()

        for (offset, blueprint) in blueprints.enumerated() {
            let release = Release(
                title: blueprint.title,
                artistName: blueprint.artist,
                releaseType: blueprint.type,
                year: blueprint.year,
                createdAt: now.addingTimeInterval(Double(-offset) * 86_400),
                updatedAt: now.addingTimeInterval(Double(-offset) * 3_600)
            )
            context.insert(release)

            for (index, title) in blueprint.trackTitles.enumerated() {
                let track = Track(
                    title: title,
                    artistName: blueprint.artist,
                    trackNumber: index + 1,
                    createdAt: now.addingTimeInterval(Double(index))
                )
                context.insert(track)
                track.release = release
                release.trackOrder.append(track.id.uuidString)

                var labels = ["Mix 5"]
                labels.append(contentsOf: blueprint.extraVersions[index] ?? [])
                for (versionOffset, label) in labels.enumerated() {
                    let asset = makeAsset(
                        title: title,
                        label: label,
                        number: index + 1,
                        availability: availability,
                        seed: offset * 100 + index * 10 + versionOffset
                    )
                    context.insert(asset)
                    let version = TrackVersion(
                        versionNumber: labels.count - versionOffset,
                        label: label,
                        audioAsset: asset,
                        createdAt: now.addingTimeInterval(Double(-versionOffset) * 3_600)
                    )
                    context.insert(version)
                    version.track = track
                    if versionOffset == 0 {
                        track.makeCurrent(version)
                    }
                }
            }
            created.append(release)
        }
        try? context.save()
        return created
    }

    private static func makeAsset(
        title: String,
        label: String,
        number: Int,
        availability: AvailabilityState,
        seed: Int
    ) -> AudioAsset {
        // Deterministic pseudo-durations between 1:38 and 5:42 so preview layouts
        // are stable between runs.
        let duration = 98.0 + Double((seed * 37) % 244)
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        let filename = String(format: "%02d %@ %@.wav", number, title, label)
        return AudioAsset(
            filename: "\(slug)-\(seed).wav",
            originalFilename: filename,
            relativePath: "Audio/00/sample-\(seed).wav",
            duration: duration,
            format: AudioFormatDescription(
                sampleRate: seed.isMultiple(of: 3) ? 44_100 : 48_000,
                bitDepth: 24,
                channelCount: 2,
                codec: "WAV"
            ),
            fileSize: Int64(duration * 48_000 * 3 * 2),
            checksum: "sample-\(seed)",
            availability: availability
        )
    }
}
