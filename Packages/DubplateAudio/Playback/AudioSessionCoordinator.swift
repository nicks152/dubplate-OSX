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

        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleInterruption(notification)
            }
        }

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleRouteChange(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value)
        else { return }

        switch type {
        case .began:
            onInterruption?(.began)
        case .ended:
            let raw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: raw)
            onInterruption?(.ended(shouldResume: options.contains(.shouldResume)))
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: value)
        else { return }

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
    public func activate() {
        isConfigured = true
    }

    public func deactivate() {}
    #endif
}
