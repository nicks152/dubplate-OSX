import Foundation
import SwiftUI
import Observation
import DubplateCore

/// Everything Dubplate lets you change.
///
/// Five of them. There is no settings application inside the application: if a
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
        static let appearance = "appearance"
        static let defaultPreviewMode = "preview.default"
        static let measuresLoudness = "analysis.loudness"
    }

    private let defaults: UserDefaults

    /// Storage is a plain observed property; each setting is a computed pair over
    /// it. `didSet` on a stored property of an `@Observable` type is not a reliable
    /// place to put a side effect — the macro rewrites those properties — and a
    /// preference that silently fails to persist is worse than no preference.
    private var values: [String: String] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.syncEnabled: true,
            Key.cellularDownloads: false,
            Key.measuresLoudness: false
        ])
        values = [
            Key.syncEnabled: String(defaults.bool(forKey: Key.syncEnabled)),
            Key.cellularDownloads: String(defaults.bool(forKey: Key.cellularDownloads)),
            Key.measuresLoudness: String(defaults.bool(forKey: Key.measuresLoudness)),
            Key.appearance: defaults.string(forKey: Key.appearance) ?? Appearance.system.rawValue,
            Key.defaultPreviewMode: defaults.string(forKey: Key.defaultPreviewMode) ?? PreviewMode.stream.rawValue
        ]
    }

    public var syncEnabled: Bool {
        get { flag(Key.syncEnabled) }
        set { set(newValue, forKey: Key.syncEnabled) }
    }

    /// A real constraint, not a preference: an album is a gigabyte, and
    /// `SyncCoordinator.canDownloadNow` refuses every transfer while this is off.
    public var allowsCellularDownloads: Bool {
        get { flag(Key.cellularDownloads) }
        set { set(newValue, forKey: Key.cellularDownloads) }
    }

    /// Loudness measurement is opt-in: it reads every file once, and a producer who
    /// does not want the number should not pay for it.
    public var measuresLoudness: Bool {
        get { flag(Key.measuresLoudness) }
        set { set(newValue, forKey: Key.measuresLoudness) }
    }

    public var appearance: Appearance {
        get { Appearance(rawValue: values[Key.appearance] ?? "") ?? .system }
        set { set(newValue.rawValue, forKey: Key.appearance) }
    }

    public var defaultPreviewMode: PreviewMode {
        get { PreviewMode(rawValue: values[Key.defaultPreviewMode] ?? "") ?? .stream }
        set { set(newValue.rawValue, forKey: Key.defaultPreviewMode) }
    }

    private func flag(_ key: String) -> Bool {
        values[key] == "true"
    }

    private func set(_ value: Bool, forKey key: String) {
        values[key] = String(value)
        defaults.set(value, forKey: key)
    }

    private func set(_ value: String, forKey key: String) {
        values[key] = value
        defaults.set(value, forKey: key)
    }

    /// Audio is never re-encoded, so there is nothing to choose. Said in About
    /// rather than dressed up as a setting that does nothing.
    public static let audioPolicy = "Dubplate plays your original files and never re-encodes them."
}
