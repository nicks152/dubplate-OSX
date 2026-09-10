import Foundation
import SwiftUI
import Observation
import DubplateCore

/// Everything Dubplate lets you change.
///
/// Eight switches. There is no settings application inside the application: if a
/// preference cannot be defended as something a producer would actually want to
/// change, it is a decision, not a setting.
@MainActor
@Observable
public final class DubplateSettings {

    public enum Appearance: String, CaseIterable, Sendable {
        case system
        case light
        case dark

        public var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        public var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    private enum Key {
        static let syncEnabled = "sync.enabled"
        static let cellularDownloads = "downloads.cellular"
        static let keepRecentOffline = "downloads.keepRecent"
        static let appearance = "appearance"
        static let defaultPreviewMode = "preview.default"
        static let measuresLoudness = "analysis.loudness"
    }

    private let defaults: UserDefaults

    public var syncEnabled: Bool { didSet { defaults.set(syncEnabled, forKey: Key.syncEnabled) } }
    public var allowsCellularDownloads: Bool { didSet { defaults.set(allowsCellularDownloads, forKey: Key.cellularDownloads) } }
    public var keepsRecentlyPlayedOffline: Bool { didSet { defaults.set(keepsRecentlyPlayedOffline, forKey: Key.keepRecentOffline) } }
    public var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    public var defaultPreviewMode: PreviewMode { didSet { defaults.set(defaultPreviewMode.rawValue, forKey: Key.defaultPreviewMode) } }
    /// Loudness measurement is opt-in: it reads every file once, and a producer who
    /// does not want the number should not pay for it.
    public var measuresLoudness: Bool { didSet { defaults.set(measuresLoudness, forKey: Key.measuresLoudness) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.syncEnabled: true,
            Key.cellularDownloads: false,
            Key.keepRecentOffline: true,
            Key.measuresLoudness: false
        ])
        syncEnabled = defaults.bool(forKey: Key.syncEnabled)
        allowsCellularDownloads = defaults.bool(forKey: Key.cellularDownloads)
        keepsRecentlyPlayedOffline = defaults.bool(forKey: Key.keepRecentOffline)
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        defaultPreviewMode = PreviewMode(rawValue: defaults.string(forKey: Key.defaultPreviewMode) ?? "") ?? .stream
        measuresLoudness = defaults.bool(forKey: Key.measuresLoudness)
    }

    /// Audio is never re-encoded, so there is nothing to choose here — but people
    /// look for the setting, so Dubplate says so plainly instead of hiding it.
    public let downloadQualityDescription = "Original files, always. Dubplate never re-encodes your audio."
}
