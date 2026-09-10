import Foundation

public extension Array {
    /// Moves the elements at `offsets` so they sit before the element currently at
    /// `destination`.
    ///
    /// This is `move(fromOffsets:toOffset:)` by another name. That method looks like
    /// part of the standard library and is not: SwiftUI adds it, in an extension on
    /// `RangeReplaceableCollection`, so it exists in every file that imports SwiftUI
    /// and in no other. `DubplateCore` holds the model and deliberately imports no
    /// UI framework, so the running order — which is a fact about a record, not
    /// about a list view — is reordered here instead.
    ///
    /// The semantics are the ones a drag gesture hands over: `destination` is an
    /// offset in the *original* array, so it has to be adjusted by however many of
    /// the moved elements were in front of it.
    mutating func moveElements(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.compactMap { indices.contains($0) ? self[$0] : nil }
        guard !moving.isEmpty else { return }

        // Highest first, so the lower indices are still valid as we go.
        for offset in offsets.sorted(by: >) where indices.contains(offset) {
            remove(at: offset)
        }

        let removedBefore = offsets.filter { $0 < destination }.count
        let insertion = Swift.min(Swift.max(destination - removedBefore, 0), count)
        insert(contentsOf: moving, at: insertion)
    }
}
