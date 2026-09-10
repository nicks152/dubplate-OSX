import Foundation
import AVFoundation
import DubplateCore

/// What the system does to playback, and what playback tells the system.
///
/// Split from the transport deliberately: everything here is a reaction to
/// something outside Dubplate — a phone call, headphones coming out, a car being
/// started, the Lock Screen asking what is playing. The other half of the
/// controller is about the record and the queue, and reads better without this
/// running through it.
extension PlayerController {

    // MARK: - Route and graph changes

    /// The engine rebuilt its graph and left the music silent. Decide whether it
    /// comes back.
    ///
    /// A rebuild happens for AirPlay, a car, a dock — and for headphones being
    /// pulled out. The notification that distinguishes them arrives separately and
    /// may arrive second, so the test here is on the outcome rather than the cause:
    /// music that was on headphones does not resume into a phone's own speaker.
    func handleConfigurationChange(wasPlaying: Bool) {
        guard wasPlaying else {
            refreshNowPlaying()
            return
        }
        if wasPlayingOnExternalRoute, session.isRoutedToBuiltInSpeaker {
            Log.audio.info("Not resuming after rebuild: output moved to the built-in speaker")
            isPlaying = false
            stopTicking()
            refreshNowPlaying()
            return
        }
        resume()
    }

    // MARK: - Interruptions

    func handle(_ interruption: AudioInterruption) {
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

    func startTicking() {
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

    func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    /// Moves the interface's playhead. Now Playing is not touched here: the system
    /// extrapolates it from the rate, and republishing on a timer costs an XPC round
    /// trip several times a second for the length of a record.
    func tick() {
        guard isPlaying else {
            lastAdvance = nil
            return
        }
        let position = engine.currentTime
        if scrubTime == nil {
            currentTime = position
        }
        checkForStall(at: position)
    }

    /// Gives up on a track that has stopped rendering without finishing.
    ///
    /// A WAV whose header promises five minutes and whose data chunk holds thirty
    /// seconds — a bounce interrupted by a full disk, or a file copied out of a
    /// share that dropped — renders what it has and then stops. The completion
    /// handler never fires, because those frames were never played back, so the
    /// transport went on counting towards a length that did not exist for as long
    /// as the application stayed open. Three seconds of a still playhead while the
    /// transport claims to be playing is not a thing that happens to a good file.
    private func checkForStall(at position: TimeInterval) {
        guard let last = lastAdvance else {
            lastAdvance = (position, Date())
            return
        }
        guard abs(position - last.position) < 0.05 else {
            lastAdvance = (position, Date())
            return
        }
        guard Date().timeIntervalSince(last.at) >= Self.stallTimeout else { return }

        lastAdvance = nil
        guard let stalled = queue.current else { return }
        Log.audio.error("Playback stalled; treating the track as finished")
        report(DubplateError(.unreadableAudio, subject: stalled.title))
        // Not `handleItemFinished`: whatever was scheduled behind this track is
        // stuck behind it on the same node and would not start either. The next
        // track has to be scheduled fresh.
        advancePastStalledItem()
    }

    /// Called when a cover changes, so the Lock Screen does not keep the old one.
    public func invalidateArtwork() {
        nowPlaying.invalidateAllArtwork()
        refreshNowPlaying()
    }

    func refreshNowPlaying() {
        let position = queue.currentIndex.map { (index: $0, count: queue.items.count) }
        nowPlaying.update(
            item: queue.current,
            isPlaying: isPlaying,
            elapsed: currentTime,
            queuePosition: position
        )
    }

    func report(_ error: DubplateError) {
        Log.audio.error("Playback error: \(error.title, privacy: .public)")
        lastError = error
    }

    public func clearError() {
        lastError = nil
    }
}
