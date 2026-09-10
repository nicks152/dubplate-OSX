import Foundation
import DubplateCore

/// One thing in the queue: a track, at a specific version, with everything the
/// player and the Lock Screen need — resolved once, so playback never reaches back
/// into the database on the audio path.
public struct PlaybackQueueItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let trackID: UUID
    public let versionID: UUID
    public let assetID: UUID
    public let relativePath: String
    public let title: String
    public let artistName: String
    public let releaseTitle: String
    public let releaseID: UUID
    public let trackNumber: Int
    public let duration: TimeInterval
    public let format: AudioFormatDescription
    public let availability: AvailabilityState
    /// Shared between every item of a release, so this costs one allocation.
    public let artworkThumbnail: Data?
    public let canvasRelativePath: String?
    /// 400 bytes of peak data for the scrubber, when the file has been measured.
    public let waveformPeaks: Data?

    public init(
        id: UUID = UUID(),
        trackID: UUID,
        versionID: UUID,
        assetID: UUID,
        relativePath: String,
        title: String,
        artistName: String,
        releaseTitle: String,
        releaseID: UUID,
        trackNumber: Int,
        duration: TimeInterval,
        format: AudioFormatDescription,
        availability: AvailabilityState,
        artworkThumbnail: Data? = nil,
        canvasRelativePath: String? = nil,
        waveformPeaks: Data? = nil
    ) {
        self.id = id
        self.trackID = trackID
        self.versionID = versionID
        self.assetID = assetID
        self.relativePath = relativePath
        self.title = title
        self.artistName = artistName
        self.releaseTitle = releaseTitle
        self.releaseID = releaseID
        self.trackNumber = trackNumber
        self.duration = duration
        self.format = format
        self.availability = availability
        self.artworkThumbnail = artworkThumbnail
        self.canvasRelativePath = canvasRelativePath
        self.waveformPeaks = waveformPeaks
    }

    public var isPlayable: Bool {
        availability.isPlayableNow && !relativePath.isEmpty
    }
}

public enum RepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one

    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// The order things will be heard in.
///
/// A value type with no dependencies, so every rule about skipping, shuffling,
/// repeating and running off the end can be tested without an audio device.
public struct PlaybackQueue: Sendable {
    public private(set) var items: [PlaybackQueueItem] = []
    /// Index into `items` of what is playing.
    public private(set) var currentIndex: Int?
    public private(set) var repeatMode: RepeatMode = .off
    public private(set) var isShuffled: Bool = false
    /// Positions in play order; `order[n]` is an index into `items`.
    private var order: [Int] = []

    public init() {}

    public init(items: [PlaybackQueueItem], startingAt index: Int = 0) {
        set(items, startingAt: index)
    }

    public var isEmpty: Bool { items.isEmpty }

    public var current: PlaybackQueueItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    /// What plays after the current item without any further input.
    public var next: PlaybackQueueItem? {
        guard let position = currentPosition else { return nil }
        if repeatMode == .one { return current }
        let nextPosition = position + 1
        if nextPosition < order.count { return items[order[nextPosition]] }
        if repeatMode == .all, let first = order.first { return items[first] }
        return nil
    }

    /// Everything still to come, in play order.
    public var upNext: [PlaybackQueueItem] {
        guard let position = currentPosition else { return [] }
        return order.dropFirst(position + 1).map { items[$0] }
    }

    private var currentPosition: Int? {
        guard let currentIndex else { return nil }
        return order.firstIndex(of: currentIndex)
    }

    // MARK: - Mutation

    public mutating func set(_ newItems: [PlaybackQueueItem], startingAt index: Int = 0) {
        items = newItems
        guard !newItems.isEmpty else {
            currentIndex = nil
            order = []
            return
        }
        currentIndex = min(max(index, 0), newItems.count - 1)
        rebuildOrder()
    }

    public mutating func clear() {
        items = []
        order = []
        currentIndex = nil
    }

    /// Moves to the next item. Returns false when the queue has run out.
    public mutating func advance(userInitiated: Bool = false) -> Bool {
        guard let position = currentPosition else { return false }
        // Repeat-one only repeats on its own; pressing next still moves on.
        if repeatMode == .one, !userInitiated { return true }

        let nextPosition = position + 1
        if nextPosition < order.count {
            currentIndex = order[nextPosition]
            return true
        }
        if repeatMode == .all, let first = order.first {
            currentIndex = first
            return true
        }
        return false
    }

    /// Moves to the previous item. Returns false at the start of the queue.
    public mutating func goBack() -> Bool {
        guard let position = currentPosition else { return false }
        if position > 0 {
            currentIndex = order[position - 1]
            return true
        }
        if repeatMode == .all, let last = order.last {
            currentIndex = last
            return true
        }
        return false
    }

    public mutating func jump(to index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }

    public mutating func jump(toItemWithID id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        currentIndex = index
    }

    public mutating func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
    }

    /// Turning shuffle on keeps whatever is playing in place and shuffles the rest,
    /// so the music does not jump when the button is pressed.
    public mutating func setShuffled(_ shuffled: Bool) {
        guard shuffled != isShuffled else { return }
        isShuffled = shuffled
        rebuildOrder()
    }

    /// Replaces one item in place — used when a different version is selected while
    /// that track is playing.
    public mutating func replace(itemWithID id: UUID, with item: PlaybackQueueItem) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = item
    }

    /// Puts an item directly after the current one.
    public mutating func playNext(_ item: PlaybackQueueItem) {
        guard let position = currentPosition else {
            set([item])
            return
        }
        items.append(item)
        order.insert(items.count - 1, at: position + 1)
    }

    public mutating func append(_ item: PlaybackQueueItem) {
        items.append(item)
        order.append(items.count - 1)
    }

    private mutating func rebuildOrder() {
        let indices = Array(items.indices)
        guard isShuffled else {
            order = indices
            return
        }
        var rest = indices.filter { $0 != currentIndex }
        rest.shuffle()
        if let currentIndex {
            order = [currentIndex] + rest
        } else {
            order = rest
        }
    }

    /// Deterministic shuffle, for tests.
    mutating func rebuildOrder(using generator: inout some RandomNumberGenerator) {
        let indices = Array(items.indices)
        guard isShuffled else {
            order = indices
            return
        }
        var rest = indices.filter { $0 != currentIndex }
        rest.shuffle(using: &generator)
        order = currentIndex.map { [$0] + rest } ?? rest
    }
}
