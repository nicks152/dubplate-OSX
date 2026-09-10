import Foundation

/// Works out what order a pile of dropped bounces should be in.
///
/// Priority, matching what producers expect: numbers in the filenames, then the
/// order Finder handed the files over in, then a natural-order filename sort.
/// The result is always immediately editable — this only decides the first guess.
public enum TrackOrdering {

    /// Why the chosen order was chosen, so the interface can say so once.
    public enum Signal: String, Sendable {
        case filenameNumbers
        case dropOrder
        case filename
    }

    public static func signal(for candidates: [ImportCandidate]) -> Signal {
        if hasReliableNumbering(candidates) { return .filenameNumbers }
        // A multi-file drag does not promise an order — the indexes are simply the
        // order the URLs arrived in, which is why this used to look decisive and
        // never was. Sort the way Finder displays instead, and say so.
        if candidates.count > 1 { return .filename }
        return .dropOrder
    }

    public static func infer(_ candidates: [ImportCandidate]) -> [ImportCandidate] {
        switch signal(for: candidates) {
        case .filenameNumbers:
            return candidates.sorted { lhs, rhs in
                let left = lhs.parsed.trackNumber ?? Int.max
                let right = rhs.parsed.trackNumber ?? Int.max
                if left != right { return left < right }
                return naturalPrecedes(lhs, rhs)
            }
        case .dropOrder:
            return candidates.sorted { $0.dropIndex < $1.dropIndex }
        case .filename:
            return candidates.sorted(by: naturalPrecedes)
        }
    }

    /// Numbers are trusted when most files carry one and none of them collide.
    static func hasReliableNumbering(_ candidates: [ImportCandidate]) -> Bool {
        let numbers = candidates.compactMap(\.parsed.trackNumber)
        guard candidates.count > 1, numbers.count >= Int(ceil(Double(candidates.count) * 0.6)) else {
            return false
        }
        return Set(numbers).count == numbers.count
    }

    /// "Track 2" before "Track 10" — the ordering Finder itself uses.
    static func naturalPrecedes(_ lhs: ImportCandidate, _ rhs: ImportCandidate) -> Bool {
        let comparison = lhs.filename.compare(
            rhs.filename,
            options: [.numeric, .caseInsensitive, .diacriticInsensitive]
        )
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.dropIndex < rhs.dropIndex
    }

    /// Orders several bounces of the *same* track oldest-first, so version numbers
    /// come out in the order they were made.
    public static func orderVersions(_ candidates: [ImportCandidate]) -> [ImportCandidate] {
        candidates.sorted { lhs, rhs in
            let left = lhs.parsed.versionOrdinal
            let right = rhs.parsed.versionOrdinal
            if let left, let right, left != right { return left < right }
            if left != nil, right == nil { return false }
            if left == nil, right != nil { return true }
            if let leftDate = lhs.creationDate, let rightDate = rhs.creationDate, leftDate != rightDate {
                return leftDate < rightDate
            }
            return lhs.dropIndex < rhs.dropIndex
        }
    }
}
