import Foundation

/// Keeping version numbers unique when two devices both add "v6".
///
/// Nothing is ever deleted to resolve this — the brief for media conflicts is that
/// both bounces survive. The later of the two simply becomes v7, decided by when it
/// was made, with the identifier as a tie-break so both devices reach the same
/// answer without talking to each other.
public enum VersionNumbering {

    public struct Entry: Hashable, Sendable {
        public let id: UUID
        public let number: Int
        public let createdAt: Date

        public init(id: UUID, number: Int, createdAt: Date) {
            self.id = id
            self.number = number
            self.createdAt = createdAt
        }
    }

    /// New numbers for any version whose number collides. Versions that are already
    /// unique keep the number they have, so labels people have said out loud
    /// ("play me v3") stay put.
    public static func resolveCollisions(_ entries: [Entry]) -> [UUID: Int] {
        var byNumber: [Int: [Entry]] = [:]
        for entry in entries {
            byNumber[entry.number, default: []].append(entry)
        }
        guard byNumber.contains(where: { $0.value.count > 1 }) else { return [:] }

        var taken = Set(entries.map(\.number))
        var assignments: [UUID: Int] = [:]

        for (number, colliding) in byNumber.sorted(by: { $0.key < $1.key }) where colliding.count > 1 {
            // Oldest keeps the number; everything after it moves up.
            let ordered = colliding.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            for entry in ordered.dropFirst() {
                var candidate = number + 1
                while taken.contains(candidate) { candidate += 1 }
                taken.insert(candidate)
                assignments[entry.id] = candidate
            }
        }
        return assignments
    }

    /// The next free number, given everything that exists.
    public static func next(after entries: [Entry]) -> Int {
        (entries.map(\.number).max() ?? 0) + 1
    }
}
