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
    public internal(set) var isPlaying = false
    /// Position in the current item, updated a few times a second while playing.
    public internal(set) var currentTime: TimeInterval = 0
    /// Set while a scrub is in progress so the bar follows the finger, not the clock.
    public var scrubTime: TimeInterval?
    public internal(set) var lastError: DubplateError?
    /// False when the next track changes sample rate, so the join cannot be
    /// gapless. Read by the release page, which is where it can be acted on.
    public private(set) var nextTransitionIsGapless = true
    /// Set when playback is holding on a track whose audio has not arrived yet.
    public private(set) var awaitingDownloadOf: PlaybackQueueItem?

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

    let engine = PlaybackEngine()
    let session = AudioSessionCoordinator()
    let nowPlaying = NowPlayingCoordinator()
    private let mediaStore: MediaStore

    var ticker: Task<Void, Never>?
    private var enqueuedItemIDs: Set<UUID> = []
    /// The item a download was requested for ahead of time, so it is asked for once.
    private var requestedAheadOf: UUID?
    var wasPlayingBeforeInterruption = false
    /// True when the music was last heard through something other than the phone's
    /// own speaker. Consulted before a rebuilt graph is restarted.
    var wasPlayingOnExternalRoute = false
    /// The last position the engine reported moving to, and when. Used to notice a
    /// track that has stopped rendering without ever finishing.
    var lastAdvance: (position: TimeInterval, at: Date)?
    /// How long the playhead may stand still before the track is given up on.
    static let stallTimeout: TimeInterval = 3

    /// Tracks passed over because their audio would not play, since the last thing
    /// the person actually asked for. Without it, repeat plus a record whose files
    /// have not arrived is a queue that never stops turning.
    private var skippedSinceUserAction: Set<UUID> = []
    /// Called when a release starts playing, so the library can record it.
    public var didStartRelease: ((UUID) -> Void)?
    /// Called when a track is asked for whose audio is not on this device.
    ///
    /// Playback waits rather than skipping: pressing play on a record that has just
    /// synced is the moment the whole product is for, and answering it by stepping
    /// through ten apologies is the worst thing Dubplate could do.
    public var needsDownload: ((PlaybackQueueItem) -> Void)?

    public init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore

        engine.itemDidFinish = { [weak self] id in
            self?.handleItemFinished(id)
        }
        engine.configurationDidChange = { [weak self] wasPlaying in
            self?.handleConfigurationChange(wasPlaying: wasPlaying)
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

    // No deinit: cancelling the ticker from one would touch main-actor state from a
    // nonisolated context. `stop()` is the lifecycle point, and the controller lives
    // as long as the process does.

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
        skippedSinceUserAction.removeAll()
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
        guard engine.hasCurrentItem else {
            // The queue ran out and the engine has nothing loaded. Start the track
            // again rather than reporting playback that is not happening.
            startCurrentItem(from: 0)
            return
        }
        session.activate()
        do {
            try engine.resume()
            isPlaying = true
            wasPlayingOnExternalRoute = !session.isRoutedToBuiltInSpeaker
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
        skippedSinceUserAction.removeAll()
        awaitingDownloadOf = nil
        isPlaying = false
        currentTime = 0
        stopTicking()
        nowPlaying.update(item: nil, isPlaying: false, elapsed: 0, queuePosition: nil)
        session.deactivate()
    }

    /// Next track. At the end of a queue this stops rather than wrapping, unless
    /// repeat is on.
    public func next() {
        skippedSinceUserAction.removeAll()
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
        skippedSinceUserAction.removeAll()
        guard queue.goBack() else {
            seek(to: 0)
            return
        }
        enqueuedItemIDs.removeAll()
        startCurrentItem(from: 0)
    }

    public func skip(to item: PlaybackQueueItem) {
        skippedSinceUserAction.removeAll()
        queue.jump(toItemWithID: item.id)
        enqueuedItemIDs.removeAll()
        startCurrentItem(from: 0)
    }

    public func seek(to time: TimeInterval) {
        let clamped = min(max(0, time), max(duration - 0.05, 0))
        do {
            try engine.seek(to: clamped)
            currentTime = clamped
            lastAdvance = nil
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
        let wasCurrent = queue.current?.id == id
        queue.replace(itemWithID: id, with: item)
        guard !wasCurrent else {
            // The engine is still rendering under the old identifier, so its
            // completion would no longer match the queue and playback would stop
            // dead at this track. Restart it in place instead.
            queue.jump(toItemWithID: item.id)
            switchToVersion(item)
            return
        }
        enqueuedItemIDs.removeAll()
        scheduleNextIfPossible()
    }

    // MARK: - Engine plumbing

    private func startCurrentItem(from offset: TimeInterval) {
        guard let item = queue.current else { return }
        guard canPlay(item) else {
            // Hold here and ask for the file, rather than skipping past it.
            //
            // The engine has to be stopped first. It is still rendering the track
            // that ran into this one, so simply setting `isPlaying = false` left
            // the previous song playing out of the headphones while the interface
            // showed this one, paused — and the next press of play resumed that
            // old track rather than this one.
            engine.stop()
            let alreadyAsking = awaitingDownloadOf?.id == item.id
            awaitingDownloadOf = item
            isPlaying = false
            stopTicking()
            refreshNowPlaying()
            if !alreadyAsking {
                needsDownload?(item)
            }
            return
        }
        awaitingDownloadOf = nil

        session.activate()
        let url = mediaStore.url(forRelativePath: item.relativePath)
        do {
            // Opening parses headers and pages in from disk. On a file that a
            // download has just put in place that is a visible hitch at a track
            // boundary, so it happens off the main actor.
            let file = try engine.openFile(at: url)
            try engine.start(item: item.id, file: file, at: offset)
            isPlaying = true
            currentTime = offset
            wasPlayingOnExternalRoute = !session.isRoutedToBuiltInSpeaker
            skippedSinceUserAction.removeAll()
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

    /// Moves past a track that would not play, and knows when to give up.
    ///
    /// `startCurrentItem` calls back into this on failure, so with repeat on and a
    /// record whose files are all unreadable the two used to call each other around
    /// the queue without end. Remembering what has already been tried since the
    /// person last asked for something turns that into one pass: every track gets a
    /// chance, and when none of them plays the record stops with an error rather
    /// than spinning.
    private func skipUnplayable() {
        isPlaying = false
        guard let failed = queue.current else {
            stopTicking()
            refreshNowPlaying()
            return
        }
        skippedSinceUserAction.insert(failed.id)

        guard queue.advance(userInitiated: true) else {
            engine.stop()
            stopTicking()
            skippedSinceUserAction.removeAll()
            refreshNowPlaying()
            return
        }
        guard let next = queue.current, !skippedSinceUserAction.contains(next.id) else {
            engine.stop()
            stopTicking()
            skippedSinceUserAction.removeAll()
            report(DubplateError(.playbackFailed, subject: failed.title))
            refreshNowPlaying()
            return
        }
        startCurrentItem(from: 0)
    }

    /// Moves to the next track after the current one stopped rendering, rebuilding
    /// the schedule rather than trusting anything already on the node.
    func advancePastStalledItem() {
        enqueuedItemIDs.removeAll()
        guard queue.advance() else {
            engine.stop()
            isPlaying = false
            stopTicking()
            refreshNowPlaying()
            return
        }
        startCurrentItem(from: 0)
    }

    /// Whether the bytes are actually on disk right now.
    ///
    /// The queue item carries a snapshot of availability taken when the record
    /// started; by the time a track is reached it may be stale in either direction.
    /// The file system is the only answer worth trusting on the audio path.
    private func canPlay(_ item: PlaybackQueueItem) -> Bool {
        !item.relativePath.isEmpty && mediaStore.exists(relativePath: item.relativePath)
    }

    /// Called once a download lands, to pick up where playback was waiting.
    public func resumeAfterDownload() {
        requestedAheadOf = nil
        guard let waiting = awaitingDownloadOf else {
            // Not stalled — a track further down the record arrived, so it can be
            // pre-scheduled and the join stays gapless.
            scheduleNextIfPossible()
            return
        }
        guard canPlay(waiting) else { return }
        awaitingDownloadOf = nil
        skippedSinceUserAction.remove(waiting.id)
        startCurrentItem(from: 0)
    }

    /// Gives up on a track that will not arrive and moves on.
    public func abandonPendingItem() {
        guard let waiting = awaitingDownloadOf else { return }
        awaitingDownloadOf = nil
        report(DubplateError(.notDownloadedYet, subject: waiting.title))
        skipUnplayable()
    }

    /// Schedules the next track on the same node so the transition is sample-exact.
    ///
    /// When the next track's audio is not here yet, ask for it now rather than
    /// waiting until the record reaches it — a partly-downloaded album should play
    /// through without stopping at the first gap.
    private func scheduleNextIfPossible() {
        guard let next = queue.next else { return }
        guard canPlay(next) else {
            if !next.relativePath.isEmpty, requestedAheadOf != next.id {
                requestedAheadOf = next.id
                needsDownload?(next)
            }
            return
        }
        guard !enqueuedItemIDs.contains(next.id) else { return }
        let url = mediaStore.url(forRelativePath: next.relativePath)
        do {
            let file = try engine.openFile(at: url)
            switch try engine.enqueue(item: next.id, file: file) {
            case .scheduled:
                enqueuedItemIDs.insert(next.id)
                nextTransitionIsGapless = true
            case .formatChanged:
                // Different sample rate: the graph has to be rebuilt at the
                // boundary, so this transition cannot be gapless.
                nextTransitionIsGapless = false
                Log.audio.info("Next track changes sample rate; transition will not be gapless")
            case .nothingPlaying, .emptyFile:
                break
            }
        } catch {
            Log.audio.error("Could not pre-schedule next track: \(String(describing: error))")
        }
    }

    private func handleItemFinished(_ id: UUID) {
        guard queue.current?.id == id else { return }

        // Repeat-one does not move, so there is nothing pre-scheduled and the track
        // has to be started again explicitly. Treating it like any other advance
        // left the transport claiming to play in silence.
        if queue.repeatMode == .one {
            enqueuedItemIDs.removeAll()
            startCurrentItem(from: 0)
            return
        }

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
}
