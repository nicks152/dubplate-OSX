import Foundation

/// A lightweight, storage-free view of a track, so matching can be tested without
/// a `ModelContainer`.
public struct TrackSummary: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let trackNumber: Int
    /// Match keys for the title and for the filename of every existing version.
    public let matchKeys: [String]

    public init(id: UUID, title: String, trackNumber: Int, matchKeys: [String]) {
        self.id = id
        self.title = title
        self.trackNumber = trackNumber
        self.matchKeys = matchKeys
    }
}

/// A proposal, never a decision.
public struct VersionMatch: Hashable, Sendable {
    public let trackID: UUID
    public let trackTitle: String
    public let confidence: Double
    /// Short phrase explaining the guess, shown in the confirmation.
    public let reason: String

    public init(trackID: UUID, trackTitle: String, confidence: Double, reason: String) {
        self.trackID = trackID
        self.trackTitle = trackTitle
        self.confidence = confidence
        self.reason = reason
    }

    /// Above this, Dubplate offers "New version of “Midnight”?" as the default action.
    public static let confidentThreshold = 0.85
    /// Below this, Dubplate says nothing at all.
    public static let suggestionThreshold = 0.70

    public var isConfident: Bool { confidence >= Self.confidentThreshold }
}

/// Decides whether a new bounce is a new version of a track you already have.
///
/// Deterministic filename heuristics only — no model, no network, no learning.
/// The result is always presented for confirmation; nothing here mutates a release.
public enum VersionMatcher {

    /// 0…1 similarity between two normalised keys, using Jaro-Winkler.
    ///
    /// Jaro-Winkler rather than edit distance because bounce names diverge at the
    /// end and agree at the start — "midnite" and "midnight" are the same song,
    /// "intro" and "outro" are not, and edit distance ranks those the same way.
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        if lhs == rhs { return 1 }
        if lhs.isEmpty || rhs.isEmpty { return 0 }
        return jaroWinkler(Array(lhs), Array(rhs))
    }

    /// How sure Dubplate is that two normalised names describe the same song,
    /// with the phrase it would use to explain itself. Zero means "say nothing".
    public static func sameSongLikelihood(_ incoming: String, _ existing: String) -> (Double, String) {
        guard !incoming.isEmpty, !existing.isEmpty else { return (0, "") }
        if incoming == existing { return (1, "Same name") }
        if weakRemainder(between: incoming, and: existing) != nil {
            return (0.94, "Same name with a new marker")
        }
        // One name contains the other, but the extra words are real words rather
        // than revision markers: "Dust" and "Dust Storm" are two songs.
        if incoming.hasPrefix(existing) || existing.hasPrefix(incoming) {
            return (0, "")
        }
        let ratio = similarity(incoming, existing)
        if ratio >= 0.90 { return (ratio, "Nearly the same name") }
        return (0, "")
    }

    /// The best candidate for a filename, or `nil` when nothing is close enough.
    public static func match(filename: String, among candidates: [TrackSummary]) -> VersionMatch? {
        let parsed = FilenameParser.parse(filename)
        var best: VersionMatch?

        for candidate in candidates {
            guard let scored = score(parsed: parsed, against: candidate) else { continue }
            if scored.confidence > (best?.confidence ?? 0) {
                best = scored
            }
        }
        guard let best, best.confidence >= VersionMatch.suggestionThreshold else { return nil }
        return best
    }

    private static func score(parsed: ParsedFilename, against candidate: TrackSummary) -> VersionMatch? {
        let key = parsed.matchKey
        guard !key.isEmpty else { return nil }

        var bestConfidence = 0.0
        var bestReason = ""

        for candidateKey in candidate.matchKeys where !candidateKey.isEmpty {
            let (confidence, reason) = sameSongLikelihood(key, candidateKey)
            if confidence > bestConfidence {
                bestConfidence = confidence
                bestReason = reason
            }
            if bestConfidence >= 1 { break }
            // Nothing in the name matched, but the file claims the same slot on the
            // record and reads similarly. Worth offering, never worth assuming.
            if bestConfidence == 0,
               let number = parsed.trackNumber,
               number == candidate.trackNumber,
               similarity(key, candidateKey) >= 0.78 {
                bestConfidence = 0.75
                bestReason = "Same track number"
            }
        }

        guard bestConfidence > 0 else { return nil }
        return VersionMatch(
            trackID: candidate.id,
            trackTitle: candidate.title,
            confidence: bestConfidence,
            reason: bestReason
        )
    }

    /// Returns non-nil when one key is the other plus revision noise.
    /// The Bool says whether the *incoming* key is the longer one.
    private static func weakRemainder(between incoming: String, and existing: String) -> Bool? {
        if incoming.hasPrefix(existing), incoming.count > existing.count {
            let extra = String(incoming.dropFirst(existing.count))
            return isWeakRemainder(extra) ? true : nil
        }
        if existing.hasPrefix(incoming), existing.count > incoming.count {
            let extra = String(existing.dropFirst(incoming.count))
            return isWeakRemainder(extra) ? false : nil
        }
        return nil
    }

    /// The remainder has already had punctuation stripped, so it is one run of
    /// characters: check it against the weak-token vocabulary by prefix peeling.
    private static func isWeakRemainder(_ remainder: String) -> Bool {
        guard !remainder.isEmpty, remainder.count <= 24 else { return false }
        var rest = Substring(remainder)
        var peeled = 0
        while !rest.isEmpty, peeled < 4 {
            let digits = rest.prefix { $0.isNumber }
            if !digits.isEmpty {
                rest = rest.dropFirst(digits.count)
                peeled += 1
                continue
            }
            var matched = false
            for token in longestFirstWeakTokens where rest.hasPrefix(token) {
                rest = rest.dropFirst(token.count)
                peeled += 1
                matched = true
                break
            }
            if !matched { return false }
        }
        return rest.isEmpty
    }

    /// Sorted once: prefix peeling must try "instrumental" before "inst".
    private static let longestFirstWeakTokens: [String] =
        FilenameParser.weakTokens.sorted { $0.count > $1.count }

    private static func jaroWinkler(_ lhs: [Character], _ rhs: [Character]) -> Double {
        let window = max(max(lhs.count, rhs.count) / 2 - 1, 0)
        var lhsMatched = [Bool](repeating: false, count: lhs.count)
        var rhsMatched = [Bool](repeating: false, count: rhs.count)
        var matches = 0

        for (index, character) in lhs.enumerated() {
            let lower = max(0, index - window)
            let upper = min(index + window + 1, rhs.count)
            guard lower < upper else { continue }
            for other in lower..<upper where !rhsMatched[other] && rhs[other] == character {
                lhsMatched[index] = true
                rhsMatched[other] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        var transpositions = 0
        var cursor = 0
        for (index, character) in lhs.enumerated() where lhsMatched[index] {
            while cursor < rhsMatched.count, !rhsMatched[cursor] { cursor += 1 }
            guard cursor < rhs.count else { break }
            if character != rhs[cursor] { transpositions += 1 }
            cursor += 1
        }
        transpositions /= 2

        let matchCount = Double(matches)
        let jaro = (matchCount / Double(lhs.count)
                    + matchCount / Double(rhs.count)
                    + (matchCount - Double(transpositions)) / matchCount) / 3

        var prefix = 0
        for index in 0..<min(4, min(lhs.count, rhs.count)) {
            if lhs[index] != rhs[index] { break }
            prefix += 1
        }
        return jaro + 0.1 * Double(prefix) * (1 - jaro)
    }
}
