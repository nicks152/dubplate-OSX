import Foundation
import AVFoundation
import Observation
import DubplateCore

/// Everything the applications need to play a record.
///
/// Owns the queue, the engine, the audio session and the Now Playing information,
/// and is the only type the interface talks to. One controller per process; both
/// applications create it at launch and keep it for the life of the app, because
/// playback outlives any screen.
@MainActor
@Observable
public final class PlayerController {

    // MARK: - Observable state

    public private(set) var queue = PlaybackQueue()
    public private(set) var isPlaying = false
    /// Position in the current item, updated a few times a second while playing.
    public private(set) var currentTime: TimeInterval = 0
    /// Set while a scrub is in progress so the bar follows the finger, not the clock.
    public var scrubTime: TimeInterval?
    public private(set) var lastError: DubplateError?
    /// True when the last transition between tracks could not be gapless because
    /// the two files have different sample rates.
    public private(set) var lastTransitionWasGapless = true

    public var currentItem: PlaybackQueueItem? { queue.current }

    /// What the scrubber should show: the finger if there is one, the clock if not.
    public var displayTime: TimeInterval {
        scrubTime ?? currentTime
    }

    public var duration: TimeInterval {
        queue.current?.duration ?? 0
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(displayTime / duration, 0), 1)
    }

    // MARK: - Collaborators

    private let engine = PlaybackEngine()
    private let session = AudioSessionCoordinator()
    private let nowPlaying = NowPlayingCoordinator()
    private let mediaStore: MediaStore

    private var ticker: Task<Void, Never>?
    private var enqueuedItemIDs: Set<UUID> = []
    private var wasPlayingBeforeInterruption = false
    /// Called when a release starts playing, so the library can record it.
    public var didStartRelease: ((UUID) -> Void)?

    public init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore

        engine.itemDidFinish = { [weak self] id in
            self?.handleItemFinished(id)
        }
        engine.configurationDidChange = { [weak self] in
            self?.refreshNowPlaying()
        }
        session.onInterruption = { [weak self] interruption in
            self?.handle(interruption)
        }

        var commands = NowPlayingCoordinator.Commands()
        commands.play = { [weak self] in self?.resume() }
        commands.pause = { [weak self] in self?.pause() }
        commands.toggle = { [weak self] in self?.togglePlayPause() }
        commands.next = { [weak self] in self?.next() }
        commands.previous = { [weak self] in self?.previous() }
        commands.seek = { [weak self] time in self?.seek(to: time) }
        commands.skipForward = { [weak self] interval in
            guard let self else { return }
            seek(to: currentTime + interval)
        }
        commands.skipBackward = { [weak self] interval in
            guard let self else { return }
            seek(to: max(0, currentTime - interval))
        }
        nowPlaying.attach(commands)
    }

    deinit {
        ticker?.cancel()
    }

    // MARK: - Starting playback

    /// Plays a sequence from a given position. This is the only entry point that
    /// replaces the queue.
    public func play(_ items: [PlaybackQueueItem], startingAt index: Int = 0, shuffled: Bool = false) {
        guard !items.isEmpty else { return }
        queue.set(items, startingAt: index)
        queue.setShuffled(shuffled)
        if shuffled, let first = queue.current {
            queue.jump(toItemWithID: first.id)
        }
        enqueuedItemIDs.removeAll()
        startCurrentItem(from: 0)
        if let releaseID = queue.current?.releaseID {
            didStartRelease?(releaseID)
        }
    }

    public func play(_ item: PlaybackQueueItem) {
        play([item])
    }

    // MARK: - Transport

    public func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    public func pause() {
        engine.pause()
        isPlaying = false
        stopTicking()
        refreshNowPlaying()
    }

    public func resume() {
        guard queue.current != nil else { return }
        session.activate()
        do {
            try engine.resume()
            isPlaying = true
            startTicking()
            refreshNowPlaying()
        } catch let error as DubplateError {
            report(error)
        } catch {
            report(DubplateError(.playbackFailed, underlying: error))
        }
    }

    public func stop() {
        engine.stop()
        queue.clear()
        enqueuedItemIDs.removeAll()
        isPlaying = false
        currentTime = 0
        stopTicking()
        nowPlaying.update(item: nil, isPlaying: false, elapsed: 0, queuePosition: nil)
        session.deactivate()
    }

    /// Next track. At the end of a queue this stops rather than wrapping, unless
    /// repeat is on.
    public func next() {
        guard queue.advance(userInitiated: true) else {
            pause()
            seek(to: 0)
            return
        }
        enqueuedItemIDs.removeAll()
        startCurrentItem(from: 0)
    }

    /// Previous track, or back to the top of this one — the convention every music
    /// player uses, and the one people's hands already know.
    public func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard queue.goBack() else {
            seek(to: 0)
            return
        }
        enqueuedItemIDs.removeAll()
        startCurrentItem(from: 0)
    }

    public func skip(to item: PlaybackQueueItem) {
        queue.jump(toItemWithID: item.id)
        enqueuedItemIDs.removeAll()
        startCurrentItem(from: 0)
    }

    public func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(duration - 0.05, 0))
        do {
            try engine.seek(to: clamped)
            currentTime = clamped
            // Anything scheduled behind the current item is now anchored to the
            // wrong sample position, so let it be re-queued from the new one.
            enqueuedItemIDs.removeAll()
            scheduleNextIfPossible()
            nowPlaying.updatePosition(elapsed: clamped, isPlaying: isPlaying)
        } catch let error as DubplateError {
            report(error)
        } catch {
            report(DubplateError(.playbackFailed, underlying: error))
        }
    }

    public func beginScrub(at time: TimeInterval) {
        scrubTime = time
    }

    public func updateScrub(to time: TimeInterval) {
        scrubTime = time
    }

    public func endScrub() {
        if let scrubTime {
            seek(to: scrubTime)
        }
        scrubTime = nil
    }

    // MARK: - Modes

    public func setShuffled(_ shuffled: Bool) {
        queue.setShuffled(shuffled)
        enqueuedItemIDs.removeAll()
        scheduleNextIfPossible()
    }

    public func cycleRepeatMode() {
        queue.setRepeatMode(queue.repeatMode.next)
        enqueuedItemIDs.removeAll()
        scheduleNextIfPossible()
    }

    public var repeatMode: RepeatMode { queue.repeatMode }
    public var isShuffled: Bool { queue.isShuffled }

    // MARK: - Versions

    /// Switches the playing track to a different version, keeping the position.
    ///
    /// This is how a producer compares two mixes: the bar does not jump, the music
    /// does not restart, the same moment is heard twice.
    public func switchToVersion(_ item: PlaybackQueueItem, keepingPosition: Bool = true) {
        guard let current = queue.current, current.trackID == item.trackID else { return }
        let position = keepingPosition ? min(currentTime, item.duration - 0.1) : 0
        queue.replace(itemWithID: current.id, with: item)
        queue.jump(toItemWithID: item.id)
        enqueuedItemIDs.removeAll()
        startCurrentItem(from: max(0, position))
    }

    /// Replaces a queue entry that is not currently playing, e.g. because the
    /// current version of a later track changed while the album is running.
    public func updateQueuedItem(_ item: PlaybackQueueItem, replacingID id: UUID) {
        queue.replace(itemWithID: id, with: item)
        if queue.current?.id != item.id {
            enqueuedItemIDs.removeAll()
            scheduleNextIfPossible()
        }
    }

    // MARK: - Engine plumbing

    private func startCurrentItem(from offset: TimeInterval) {
        guard let item = queue.current else { return }
        guard item.isPlayable else {
            report(DubplateError(.notDownloadedYet, subject: item.title))
            // Do not stall the record on one missing file: move on if there is more.
            if queue.advance(userInitiated: true) {
                startCurrentItem(from: 0)
            } else {
                pause()
            }
            return
        }

        session.activate()
        let url = mediaStore.url(forRelativePath: item.relativePath)
        do {
            let file = try engine.openFile(at: url)
            try engine.start(item: item.id, file: file, at: offset)
            isPlaying = true
            currentTime = offset
            enqueuedItemIDs = [item.id]
            startTicking()
            refreshNowPlaying()
            scheduleNextIfPossible()
        } catch let error as DubplateError {
            report(error)
            skipUnplayable()
        } catch {
            report(DubplateError(.playbackFailed, subject: item.title, underlying: error))
            skipUnplayable()
        }
    }

    private func skipUnplayable() {
        isPlaying = false
        if queue.advance(userInitiated: true) {
            startCurrentItem(from: 0)
        }
    }

    /// Schedules the next track on the same node so the transition is sample-exact.
    private func scheduleNextIfPossible() {
        guard let next = queue.next, next.isPlayable, !enqueuedItemIDs.contains(next.id) else { return }
        let url = mediaStore.url(forRelativePath: next.relativePath)
        do {
            let file = try engine.openFile(at: url)
            guard engine.canFollow(file.processingFormat) else {
                // Different sample rate: the graph has to be rebuilt at the
                // boundary, so this transition cannot be gapless. Say so once.
                lastTransitionWasGapless = false
                Log.audio.info("Next track changes sample rate; transition will not be gapless")
                return
            }
            if try engine.enqueue(item: next.id, file: file) {
                enqueuedItemIDs.insert(next.id)
                lastTransitionWasGapless = true
            }
        } catch {
            Log.audio.error("Could not pre-schedule next track: \(String(describing: error))")
        }
    }

    private func handleItemFinished(_ id: UUID) {
        guard queue.current?.id == id else { return }
        guard queue.advance() else {
            isPlaying = false
            currentTime = duration
            stopTicking()
            refreshNowPlaying()
            return
        }
        if let item = queue.current, enqueuedItemIDs.contains(item.id) {
            // Already rendering: the audio never stopped. Catch the interface up.
            currentTime = 0
            refreshNowPlaying()
            scheduleNextIfPossible()
        } else {
            startCurrentItem(from: 0)
        }
    }

    // MARK: - Interruptions

    private func handle(_ interruption: AudioInterruption) {
        switch interruption {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            pause()
        case .ended(let shouldResume):
            if shouldResume, wasPlayingBeforeInterruption {
                resume()
            }
            wasPlayingBeforeInterruption = false
        case .routeLost:
            pause()
        case .routeChanged:
            refreshNowPlaying()
        }
    }

    // MARK: - Ticking

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                await MainActor.run {
                    self.tick()
                }
            }
        }
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard isPlaying else { return }
        if scrubTime == nil {
            currentTime = engine.currentTime
        }
        nowPlaying.updatePosition(elapsed: currentTime, isPlaying: isPlaying)
    }

    private func refreshNowPlaying() {
        let position = queue.currentIndex.map { (index: $0, count: queue.items.count) }
        nowPlaying.update(
            item: queue.current,
            isPlaying: isPlaying,
            elapsed: currentTime,
            queuePosition: position
        )
    }

    private func report(_ error: DubplateError) {
        Log.audio.error("Playback error: \(error.title, privacy: .public)")
        lastError = error
    }

    public func clearError() {
        lastError = nil
    }
}
