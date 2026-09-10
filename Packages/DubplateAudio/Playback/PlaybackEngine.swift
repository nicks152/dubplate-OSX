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
    /// Sample position of the start of the current render session.
    private var sessionStartSample: AVAudioFramePosition = 0
    private var currentFormat: AVAudioFormat?
    private var isConnected = false

    public private(set) var isPlaying = false
    public private(set) var currentItemID: UUID?

    /// Called on the main actor when a scheduled item has finished rendering.
    public var itemDidFinish: ((UUID) -> Void)?
    /// Called when the engine had to be rebuilt underneath playback.
    public var configurationDidChange: (() -> Void)?

    public init() {
        engine.attach(player)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
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

        sessionStartSample = 0
        currentItemID = id
        try schedule(id: id, file: file, from: offset, startingAt: 0)
        player.play()
        isPlaying = true
    }

    /// Queues an item to render immediately after everything already scheduled.
    /// Returns false when the format differs and a rebuild is required.
    @discardableResult
    public func enqueue(item id: UUID, file: AVAudioFile) throws -> Bool {
        guard canFollow(file.processingFormat) else { return false }
        guard let last = scheduled.last else { return false }
        try schedule(id: id, file: file, from: 0, startingAt: last.startSample + last.frameCount)
        return true
    }

    /// Drops everything queued behind the current item — used when the queue
    /// changes while playing.
    public func clearPending() {
        guard scheduled.count > 1 else { return }
        // AVAudioPlayerNode cannot cancel a single scheduled file, so re-anchor by
        // restarting from the current position with only the current item.
        guard let current = scheduled.first, let currentItemID else { return }
        let position = currentTime
        try? start(item: currentItemID, file: current.file, at: position)
    }

    public func pause() {
        guard isPlaying else { return }
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
              let entry = scheduled.first(where: { $0.itemID == currentItemID }),
              let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime)
        else {
            return 0
        }
        let elapsed = playerTime.sampleTime - sessionStartSample - entry.startSample
        let frame = entry.fileStartFrame + max(0, elapsed)
        return Double(frame) / entry.sampleRate
    }

    /// Seconds left in the current item, used to decide when to pre-schedule.
    public var remainingTime: TimeInterval {
        guard let currentItemID,
              let entry = scheduled.first(where: { $0.itemID == currentItemID })
        else {
            return 0
        }
        let total = Double(entry.fileStartFrame + entry.frameCount) / entry.sampleRate
        return max(0, total - currentTime)
    }

    // MARK: - Internals

    private func schedule(
        id: UUID,
        file: AVAudioFile,
        from offset: TimeInterval,
        startingAt startSample: AVAudioFramePosition
    ) throws {
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = min(
            AVAudioFramePosition(max(0, offset) * sampleRate),
            max(0, file.length - 1)
        )
        let frameCount = file.length - startFrame
        guard frameCount > 0 else {
            // An empty or fully-consumed file: report it as finished rather than
            // scheduling zero frames, which AVAudioPlayerNode treats as an error.
            itemDidFinish?(id)
            return
        }

        let entry = Scheduled(
            itemID: id,
            file: file,
            startSample: startSample,
            frameCount: frameCount,
            fileStartFrame: startFrame,
            sampleRate: sampleRate
        )
        scheduled.append(entry)

        player.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(frameCount),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            // Fires on an AVFoundation-owned thread.
            Task { @MainActor [weak self] in
                self?.handleFinished(id: id)
            }
        }
    }

    private func handleFinished(id: UUID) {
        guard scheduled.contains(where: { $0.itemID == id }) else { return }
        scheduled.removeAll { $0.itemID == id }
        if currentItemID == id {
            currentItemID = scheduled.first?.itemID
        }
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
        isConnected = false
        currentFormat = nil
        do {
            try start(item: currentItemID, file: entry.file, at: position)
            if !wasPlaying {
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
