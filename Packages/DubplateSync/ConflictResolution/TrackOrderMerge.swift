import Foundation

/// Reconciling a release's sequence after two devices have both edited it.
///
/// CloudKit has no ordered relationship, so the sequence travels as an array and is
/// merged last-writer-wins like any other value. That is fine for the order itself
/// — the most recent complete ordering is the one the person meant — but it is not
/// fine for membership: a track added on the Mac while the phone was reordering
/// must not disappear because the phone's array won.
///
/// So: the winning array decides *order*, and the relationship decides *membership*.
public enum TrackOrderMerge {

    /// - Parameters:
    ///   - order: the ordering that won the merge, as track identifiers.
    ///   - present: every track that actually exists on the release now.
    ///   - creationOrder: those same identifiers, oldest first, for placing
    ///     anything the winning order never knew about.
    /// - Returns: a complete ordering with no duplicates and nothing missing.
    public static func reconcile(
        order: [String],
        present: [String],
        creationOrder: [String]
    ) -> [String] {
        let existing = Set(present)
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(present.count)

        for identifier in order where existing.contains(identifier) && !seen.contains(identifier) {
            seen.insert(identifier)
            result.append(identifier)
        }

        // Tracks the winning order had never heard of go on the end, in the order
        // they were made, rather than being dropped.
        for identifier in creationOrder where existing.contains(identifier) && !seen.contains(identifier) {
            seen.insert(identifier)
            result.append(identifier)
        }

        // Belt and braces: anything still unplaced.
        for identifier in present where !seen.contains(identifier) {
            seen.insert(identifier)
            result.append(identifier)
        }
        return result
    }

    /// True when the stored order needs rewriting.
    public static func needsReconciling(order: [String], present: [String]) -> Bool {
        order.count != present.count || Set(order) != Set(present) || Set(order).count != order.count
    }
}
