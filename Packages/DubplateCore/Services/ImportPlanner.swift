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
    /// Set on an uncertain match: the new track this bounce will become unless the
    /// person says it is a mix of the track Dubplate half-recognised.
    public var fallbackTrackID: UUID?

    public init(candidate: ImportCandidate, match: VersionMatch, fallbackTrackID: UUID? = nil) {
        self.candidate = candidate
        self.match = match
        self.fallbackTrackID = fallbackTrackID
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
    /// Bounces that look like they might belong to a track already on the record,
    /// but not confidently enough to act on. They are planned as new tracks; the
    /// confirmation sheet offers to make them mixes instead.
    public var uncertainVersions: [PlannedVersion] = []
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
            parts.append("\(newVersions.count) new mix\(newVersions.count == 1 ? "" : "es")")
        }
        if !uncertainVersions.isEmpty {
            parts.append("\(uncertainVersions.count) to check")
        }
        if !artwork.isEmpty { parts.append("artwork") }
        if !motion.isEmpty { parts.append("a looping visual") }
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
                        reason: "Dubplate plays WAV, AIFF, CAF, FLAC, ALAC, AAC, M4A and MP3"
                    )
                )
            }
        }

        guard !audio.isEmpty else { return plan }
        plan.orderingSignal = TrackOrdering.signal(for: audio)

        // Split into bounces of tracks we already have and genuinely new material.
        var unmatched: [ImportCandidate] = []
        var uncertain: [UUID: VersionMatch] = [:]
        for candidate in audio {
            let match = VersionMatcher.match(filename: candidate.filename, among: existingTracks)
            if let match, match.isConfident {
                plan.newVersions.append(PlannedVersion(candidate: candidate, match: match))
            } else {
                if let match { uncertain[candidate.id] = match }
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
            let planned = PlannedTrack(title: title, trackNumber: number, candidates: ordered)
            plan.newTracks.append(planned)
            for candidate in ordered {
                if let match = uncertain[candidate.id] {
                    plan.uncertainVersions.append(
                        PlannedVersion(candidate: candidate, match: match, fallbackTrackID: planned.id)
                    )
                }
            }
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
