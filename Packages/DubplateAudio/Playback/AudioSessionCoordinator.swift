import Foundation
import AVFoundation
import DubplateCore

/// What the system did to playback while we were not looking.
public enum AudioInterruption: Sendable {
    /// A call, Siri, or another application took the audio route.
    case began
    /// The interruption ended. `shouldResume` reflects the system's advice, which
    /// Dubplate follows: music that was playing before a call comes back, music
    /// paused by another app taking over does not.
    case ended(shouldResume: Bool)
    /// Headphones were unplugged or AirPods were removed. Playback must pause.
    case routeLost
    /// A new route arrived (AirPlay, a car, a dock). Playback continues.
    case routeChanged
}

/// Owns the audio session on iOS, and stays out of the way on macOS.
///
/// macOS has no `AVAudioSession`: an application simply plays, and route changes
/// arrive through the engine's own configuration-change notification. The
/// coordinator exists on both platforms so callers never need `#if os(iOS)`.
@MainActor
public final class AudioSessionCoordinator {
    public var onInterruption: ((AudioInterruption) -> Void)?
    private var isConfigured = false

    public init() {}

    #if os(iOS)
    /// Whether audio would come out of the phone's own speaker right now.
    ///
    /// Asked before resuming after the engine rebuilds itself: a rebuild that
    /// happens to coincide with headphones coming out must not put an unreleased
    /// record into the room.
    public var isRoutedToBuiltInSpeaker: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .builtInSpeaker
        }
    }

    public func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            if !isConfigured {
                // .playback keeps audio going with the screen locked and honours the
                // ring/silent switch the way a music application should. No mixing:
                // a record deserves the whole output.
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                observeNotifications()
                isConfigured = true
            }
            try session.setActive(true)
        } catch {
            Log.audio.error("Could not activate audio session: \(String(describing: error))")
        }
    }

    public func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Log.audio.error("Could not deactivate audio session: \(String(describing: error))")
        }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        // The notification is read here, where it arrives, and only plain values
        // cross to the main actor. A `Task { @MainActor }` hop rather than
        // `assumeIsolated`: the queue is main today, but asserting isolation from a
        // queue is an assumption, and under strict concurrency a wrong one traps
        // rather than warns.
        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo
            let type = (info?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(
                rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            )
            guard let type else { return }
            let shouldResume = options.contains(.shouldResume)
            Task { @MainActor [weak self] in
                self?.handleInterruption(type, shouldResume: shouldResume)
            }
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard let reason else { return }
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reason)
            }
        }
    }

    private func handleInterruption(
        _ type: AVAudioSession.InterruptionType,
        shouldResume: Bool
    ) {
        switch type {
        case .began:
            onInterruption?(.began)
        case .ended:
            onInterruption?(.ended(shouldResume: shouldResume))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones out. Never keep playing out of the speaker.
            onInterruption?(.routeLost)
        case .newDeviceAvailable, .override, .routeConfigurationChange:
            onInterruption?(.routeChanged)
        default:
            break
        }
    }
    #else
    /// A Mac has no built-in-speaker special case: unplugging headphones moves the
    /// output to whatever the person chose in Sound, which is their decision.
    public var isRoutedToBuiltInSpeaker: Bool { false }

    public func activate() {
        isConfigured = true
    }

    public func deactivate() {}
    #endif
}
