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
        guard isPlaying else { return }
        if scrubTime == nil {
            currentTime = engine.currentTime
        }
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
