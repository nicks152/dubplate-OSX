import Foundation
import AVFoundation
import DubplateCore

/// Plays audio files back-to-back without inserting a gap.
///
/// Built on `AVAudioEngine` and a single `AVAudioPlayerNode` rather than
/// `AVQueuePlayer`, because a player node renders consecutively scheduled files
/// sample-accurately: the last frame of one track is followed by the first frame of
/// the next with nothing in between. That is what an album, a live set or a DJ mix
/// needs, and it is not something a queue of `AVPlayerItem`s can promise.
///
/// The one place a gap is unavoidable is a change of sample rate or channel count
/// between two tracks, because the node's output format has to be rebuilt. The
/// engine detects that in advance (`canFollow`) and the controller reports it.
///
/// Audio is never converted, resampled or normalised. Files are scheduled in their
/// own processing format and the mixer handles the device conversion, exactly as it
/// would for any other application.
@MainActor
public final class PlaybackEngine {

    /// A file scheduled on the player node, and where it sits in the render timeline.
    private struct Scheduled {
        /// Identifies this *scheduling*, not this item.
        ///
        /// `AVAudioPlayerNode.stop()` fires the completion handler of everything it
        /// had scheduled. Keying on the item's identifier meant a seek — which stops
        /// and re-schedules the same item — saw the old handler fire against the new
        /// entry and reported the track as finished, so every scrub skipped to the
        /// next track. The token makes a completion belong to one `scheduleSegment`
        /// call and nothing else.
        let generation: UInt64
        let itemID: UUID
        let file: AVAudioFile
        /// Frame the item starts at, measured on the node's sample clock.
        let startSample: AVAudioFramePosition
        /// Frames of the file actually scheduled (a seek schedules a segment).
        let frameCount: AVAudioFramePosition
        /// Frame inside the file that `startSample` corresponds to.
        let fileStartFrame: AVAudioFramePosition
        let sampleRate: Double
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var scheduled: [Scheduled] = []
    private var currentFormat: AVAudioFormat?
    private var isConnected = false
    private var nextGeneration: UInt64 = 0
    /// The last position known while the node was running. `playerTime` returns nil
    /// once the node is paused, so without this a route change while paused would
    /// restart the track from the beginning.
    private var pausedAt: TimeInterval = 0

    public private(set) var isPlaying = false
    public private(set) var currentItemID: UUID?

    /// Called on the main actor when a scheduled item has finished rendering.
    public var itemDidFinish: ((UUID) -> Void)?
    /// Called when the engine had to be rebuilt underneath playback.
    public var configurationDidChange: (() -> Void)?

    /// Kept so the observer can be removed; one leaked observer per engine is one
    /// too many for something this long-lived.
    private var configurationObserver: (any NSObjectProtocol)?

    public init() {
        engine.attach(player)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // A Task hop rather than `assumeIsolated`: the queue is main today, but
            // asserting isolation from a queue is an assumption, not a guarantee.
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - Loading

    public func openFile(at url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw DubplateError(.unreadableAudio, subject: url.lastPathComponent, underlying: error)
        }
    }

    /// Whether `format` can be scheduled straight after what is already playing.
    public func canFollow(_ format: AVAudioFormat) -> Bool {
        guard let currentFormat else { return true }
        return currentFormat.sampleRate == format.sampleRate
            && currentFormat.channelCount == format.channelCount
    }

    // MARK: - Transport

    /// Starts an item, discarding anything currently scheduled.
    public func start(item id: UUID, file: AVAudioFile, at offset: TimeInterval = 0) throws {
        player.stop()
        scheduled.removeAll()

        try connect(for: file.processingFormat)
        try startEngineIfNeeded()

        currentItemID = id
        pausedAt = offset
        guard try schedule(id: id, file: file, from: offset, startingAt: 0) else {
            // Nothing to render — an empty or truncated file. Report it and leave
            // the transport stopped rather than claiming to be playing silence.
            isPlaying = false
            currentItemID = nil
            reportFinished(id)
            return
        }
        player.play()
        isPlaying = true
    }

    /// Queues an item to render immediately after everything already scheduled.
    /// Returns false when the format differs and a rebuild is required.
    /// Why an enqueue did not happen, so the caller can tell the cases apart.
    public enum EnqueueResult {
        case scheduled
        case formatChanged
        case nothingPlaying
        case emptyFile
    }

    @discardableResult
    public func enqueue(item id: UUID, file: AVAudioFile) throws -> EnqueueResult {
        guard let last = scheduled.last else { return .nothingPlaying }
        guard canFollow(file.processingFormat) else { return .formatChanged }
        let didSchedule = try schedule(
            id: id,
            file: file,
            from: 0,
            startingAt: last.startSample + last.frameCount
        )
        return didSchedule ? .scheduled : .emptyFile
    }

    public func pause() {
        guard isPlaying else { return }
        pausedAt = currentTime
        player.pause()
        isPlaying = false
    }

    public func resume() throws {
        guard !isPlaying, currentItemID != nil else { return }
        try startEngineIfNeeded()
        player.play()
        isPlaying = true
    }

    public func stop() {
        player.stop()
        engine.stop()
        scheduled.removeAll()
        currentItemID = nil
        isPlaying = false
        isConnected = false
        currentFormat = nil
        pausedAt = 0
    }

    /// Whether the engine still has something to render. Used by the controller to
    /// tell "paused mid-track" apart from "the queue ran out".
    public var hasCurrentItem: Bool {
        currentItemID != nil
    }

    /// Seeks inside the current item.
    public func seek(to time: TimeInterval) throws {
        guard let currentItemID, let current = scheduled.first(where: { $0.itemID == currentItemID })
        else { return }
        let wasPlaying = isPlaying
        try start(item: currentItemID, file: current.file, at: max(0, time))
        if !wasPlaying {
            player.pause()
            isPlaying = false
        }
    }

    // MARK: - Position

    /// Seconds into the current item.
    public var currentTime: TimeInterval {
        guard let currentItemID,
              let entry = scheduled.first(where: { $0.itemID == currentItemID })
        else {
            return pausedAt
        }
        guard let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime)
        else {
            // The node is not running: `playerTime` is nil while paused, and
            // answering zero here is what used to restart a paused track from the
            // beginning after a route change.
            return pausedAt
        }
        let elapsed = playerTime.sampleTime - entry.startSample
        let frame = entry.fileStartFrame + max(0, elapsed)
        return Double(frame) / entry.sampleRate
    }

    // MARK: - Internals

    /// Returns false when there was nothing to schedule.
    ///
    /// Never calls `itemDidFinish` itself: doing so re-entered `start` from inside
    /// `start`, which recursed through a queue of truncated files and left the
    /// transport claiming to play with nothing scheduled.
    @discardableResult
    private func schedule(
        id: UUID,
        file: AVAudioFile,
        from offset: TimeInterval,
        startingAt startSample: AVAudioFramePosition
    ) throws -> Bool {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return false }
        let startFrame = min(
            AVAudioFramePosition(max(0, offset) * sampleRate),
            max(0, file.length - 1)
        )
        let frameCount = file.length - startFrame
        guard frameCount > 0 else { return false }

        nextGeneration += 1
        let generation = nextGeneration
        scheduled.append(
            Scheduled(
                generation: generation,
                itemID: id,
                file: file,
                startSample: startSample,
                frameCount: frameCount,
                fileStartFrame: startFrame,
                sampleRate: sampleRate
            )
        )

        player.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(frameCount),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            // Fires on an AVFoundation-owned thread.
            Task { @MainActor [weak self] in
                self?.handleFinished(generation: generation)
            }
        }
        return true
    }

    private func handleFinished(generation: UInt64) {
        // A completion from a scheduling that has already been superseded — by a
        // seek, a rebuild, or a new track — is not this track ending.
        guard let index = scheduled.firstIndex(where: { $0.generation == generation }) else { return }
        let entry = scheduled.remove(at: index)
        if currentItemID == entry.itemID {
            pausedAt = 0
            currentItemID = scheduled.first?.itemID
        }
        reportFinished(entry.itemID)
    }

    private func reportFinished(_ id: UUID) {
        itemDidFinish?(id)
    }

    private func connect(for format: AVAudioFormat) throws {
        if isConnected, let currentFormat,
           currentFormat.sampleRate == format.sampleRate,
           currentFormat.channelCount == format.channelCount {
            return
        }
        if isConnected {
            engine.disconnectNodeOutput(player)
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        currentFormat = format
        isConnected = true
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw DubplateError(.playbackFailed, underlying: error)
        }
    }

    /// A route change (headphones out, AirPlay in) tears the engine's graph down.
    /// Rebuild it and pick up where the music was.
    private func handleConfigurationChange() {
        Log.audio.info("Audio engine configuration changed; rebuilding graph")
        guard let currentItemID,
              let entry = scheduled.first(where: { $0.itemID == currentItemID })
        else {
            isConnected = false
            currentFormat = nil
            return
        }
        let position = currentTime
        let wasPlaying = isPlaying
        let pending = scheduled.filter { $0.itemID != currentItemID }
        isConnected = false
        currentFormat = nil
        do {
            try start(item: currentItemID, file: entry.file, at: position)
            // Put back whatever was queued behind it, so the next boundary is still
            // gapless after a headphone change.
            for item in pending {
                _ = try? enqueue(item: item.itemID, file: item.file)
            }
            if !wasPlaying {
                pausedAt = position
                player.pause()
                isPlaying = false
            }
        } catch {
            Log.audio.error("Could not rebuild audio graph: \(String(describing: error))")
            isPlaying = false
        }
        configurationDidChange?()
    }
}
