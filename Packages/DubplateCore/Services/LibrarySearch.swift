import Foundation

/// One thing a search can find.
public struct SearchResult: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case release
        case track
        case version
    }

    public let id: UUID
    public let kind: Kind
    public let title: String
    public let subtitle: String
    /// The release this result belongs to, so the interface can navigate to it.
    public let releaseID: UUID?
    public let score: Double

    public init(
        id: UUID,
        kind: Kind,
        title: String,
        subtitle: String,
        releaseID: UUID?,
        score: Double
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.releaseID = releaseID
        self.score = score
    }
}

/// Something searchable, flattened out of the store so ranking stays testable.
public struct SearchEntry: Hashable, Sendable {
    public let id: UUID
    public let kind: SearchResult.Kind
    public let title: String
    public let subtitle: String
    public let releaseID: UUID?
    /// Artist, filenames, version labels — matched but not displayed as the title.
    public let secondaryText: [String]

    public init(
        id: UUID,
        kind: SearchResult.Kind,
        title: String,
        subtitle: String,
        releaseID: UUID?,
        secondaryText: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.releaseID = releaseID
        self.secondaryText = secondaryText
    }
}

/// Local, immediate search over releases, tracks, artists and filenames.
///
/// Small enough to run on every keystroke for a library of a few thousand tracks,
/// which is the size Dubplate is built for. No index to keep in step, nothing to
/// invalidate, nothing to sync.
public enum LibrarySearch {

    public static func run(query: String, over entries: [SearchEntry], limit: Int = 40) -> [SearchResult] {
        let needle = FilenameParser.normalize(query)
        guard !needle.isEmpty else { return [] }

        var results: [SearchResult] = []
        for entry in entries {
            guard let score = score(needle: needle, entry: entry) else { continue }
            results.append(
                SearchResult(
                    id: entry.id,
                    kind: entry.kind,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    releaseID: entry.releaseID,
                    score: score
                )
            )
        }
        return results
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.kind != rhs.kind { return rank(lhs.kind) < rank(rhs.kind) }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func rank(_ kind: SearchResult.Kind) -> Int {
        switch kind {
        case .release: return 0
        case .track: return 1
        case .version: return 2
        }
    }

    private static func score(needle: String, entry: SearchEntry) -> Double? {
        var best: Double?
        let title = FilenameParser.normalize(entry.title)
        if let value = fieldScore(needle: needle, haystack: title, weight: 1) {
            best = max(best ?? 0, value)
        }
        for text in entry.secondaryText {
            let normalized = FilenameParser.normalize(text)
            if let value = fieldScore(needle: needle, haystack: normalized, weight: 0.7) {
                best = max(best ?? 0, value)
            }
        }
        return best
    }

    private static func fieldScore(needle: String, haystack: String, weight: Double) -> Double? {
        guard !haystack.isEmpty else { return nil }
        if haystack == needle { return 1 * weight }
        if haystack.hasPrefix(needle) { return 0.9 * weight }
        if haystack.contains(needle) { return 0.75 * weight }
        // Typo tolerance, but only for queries long enough for it to mean something.
        if needle.count >= 4 {
            let similarity = VersionMatcher.similarity(needle, haystack)
            if similarity >= 0.88 { return similarity * 0.6 * weight }
        }
        return nil
    }
}
