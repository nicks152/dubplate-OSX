import SwiftUI
import SwiftData
import DubplateCore
import DubplateUI

/// Dubplate for Mac: the room where records get made.
@main
struct DubplateMacApp: App {
    @State private var services = AppServices.live()

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(services)
                .environment(services.library)
                .environment(services.player)
                .environment(services.artwork)
                .environment(services.sync)
                .environment(services.settings)
                .modelContainer(services.container)
                .preferredColorScheme(services.settings.appearance.colorScheme)
                .task { await services.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands { DubplateCommands(services: services) }

        Settings {
            MacSettingsView()
                .environment(services)
                .environment(services.settings)
                .environment(services.sync)
        }
    }
}

/// Menu bar commands.
///
/// Only what a producer reaches for: making a record, importing bounces, and the
/// transport. Everything else lives where it is used.
struct DubplateCommands: Commands {
    let services: AppServices
    @FocusedValue(\.selectedRelease) private var selectedRelease

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Release…") {
                NotificationCenter.default.post(name: .dubplateNewRelease, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Import Audio…") {
                NotificationCenter.default.post(name: .dubplateImportAudio, object: nil)
            }
            .keyboardShortcut("i", modifiers: .command)
        }

        CommandMenu("Playback") {
            Button(services.player.isPlaying ? "Pause" : "Play") {
                services.player.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Next Track") { services.player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)

            Button("Previous Track") { services.player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)

            Divider()

            Button("Shuffle") { services.player.setShuffled(!services.player.isShuffled) }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Repeat") { services.player.cycleRepeatMode() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Button("Phone Preview") {
                NotificationCenter.default.post(name: .dubplateTogglePreview, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let dubplateNewRelease = Notification.Name("dubplate.newRelease")
    static let dubplateImportAudio = Notification.Name("dubplate.importAudio")
    static let dubplateTogglePreview = Notification.Name("dubplate.togglePreview")
}

/// Lets the menu bar know which release the window is showing.
struct SelectedReleaseKey: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var selectedRelease: UUID? {
        get { self[SelectedReleaseKey.self] }
        set { self[SelectedReleaseKey.self] = newValue }
    }
}
