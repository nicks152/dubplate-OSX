import Foundation

/// A new track Dubplate intends to create, with every bounce that belongs to it.
public struct PlannedTrack: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var title: String
    public var trackNumber: Int
    /// Oldest first: the last one becomes the current version.
    public var candidates: [ImportCandidate]

    public init(title: String, trackNumber: Int, candidates: [ImportCandidate]) {
        self.title = title
        self.trackNumber = trackNumber
        self.candidates = candidates
    }
}

/// A bounce Dubplate believes belongs to a track that already exists.
public struct PlannedVersion: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var candidate: ImportCandidate
    public var match: VersionMatch

    public init(candidate: ImportCandidate, match: VersionMatch) {
        self.candidate = candidate
        self.match = match
    }
}

public struct RejectedFile: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public var filename: String
    public var reason: String

    public init(filename: String, reason: String) {
        self.filename = filename
        self.reason = reason
    }
}

/// Everything a drop is about to do, before it does any of it.
public struct ImportPlan: Sendable {
    public var newTracks: [PlannedTrack] = []
    public var newVersions: [PlannedVersion] = []
    public var artwork: [ImportCandidate] = []
    public var motion: [ImportCandidate] = []
    public var rejected: [RejectedFile] = []
    public var orderingSignal: TrackOrdering.Signal = .filename

    public var isEmpty: Bool {
        newTracks.isEmpty && newVersions.isEmpty && artwork.isEmpty && motion.isEmpty
    }

    public var audioFileCount: Int {
        newTracks.reduce(0) { $0 + $1.candidates.count } + newVersions.count
    }

    /// One line describing the drop: "8 tracks · 1 new version · cover".
    public var summary: String {
        var parts: [String] = []
        if !newTracks.isEmpty {
            parts.append("\(newTracks.count) track\(newTracks.count == 1 ? "" : "s")")
        }
        if !newVersions.isEmpty {
            parts.append("\(newVersions.count) new version\(newVersions.count == 1 ? "" : "s")")
        }
        if !artwork.isEmpty { parts.append("cover") }
        if !motion.isEmpty { parts.append("motion") }
        if !rejected.isEmpty {
            parts.append("\(rejected.count) skipped")
        }
        return parts.joined(separator: " · ")
    }
}

/// Turns a drop into a plan.
///
/// The planner never touches disk and never touches the store, which is what makes
/// the "what is about to happen" sheet trustworthy and the whole thing testable.
public enum ImportPlanner {

    public static func plan(
        candidates: [ImportCandidate],
        existingTracks: [TrackSummary] = [],
        nextTrackNumber: Int = 1
    ) -> ImportPlan {
        var plan = ImportPlan()

        var audio: [ImportCandidate] = []
        for candidate in candidates {
            if candidate.isAudio {
                audio.append(candidate)
            } else if candidate.isImage {
                plan.artwork.append(candidate)
            } else if candidate.isVideo {
                plan.motion.append(candidate)
            } else {
                plan.rejected.append(
                    RejectedFile(
                        filename: candidate.filename,
                        reason: "Dubplate doesn’t recognise this kind of file"
                    )
                )
            }
        }

        guard !audio.isEmpty else { return plan }
        plan.orderingSignal = TrackOrdering.signal(for: audio)

        // Split into bounces of tracks we already have and genuinely new material.
        var unmatched: [ImportCandidate] = []
        for candidate in audio {
            if let match = VersionMatcher.match(filename: candidate.filename, among: existingTracks),
               match.isConfident {
                plan.newVersions.append(PlannedVersion(candidate: candidate, match: match))
            } else {
                unmatched.append(candidate)
            }
        }

        // Group the rest: several bounces of the same unknown song become one track.
        var groups: [String: [ImportCandidate]] = [:]
        var groupOrder: [String] = []
        for candidate in TrackOrdering.infer(unmatched) {
            let key = groupingKey(for: candidate, existing: groupOrder)
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(candidate)
        }

        var number = nextTrackNumber
        for key in groupOrder {
            guard let members = groups[key] else { continue }
            let ordered = TrackOrdering.orderVersions(members)
            let title = ordered.first?.parsed.title ?? "Untitled"
            plan.newTracks.append(
                PlannedTrack(title: title, trackNumber: number, candidates: ordered)
            )
            number += 1
        }
        return plan
    }

    /// Files dropped in one go that clearly describe the same song share a key.
    private static func groupingKey(for candidate: ImportCandidate, existing: [String]) -> String {
        let key = candidate.parsed.matchKey
        guard !key.isEmpty else { return candidate.filename.lowercased() }
        for other in existing where other != key {
            if VersionMatcher.sameSongLikelihood(key, other).0 >= 0.90 { return other }
        }
        return key
    }
}
