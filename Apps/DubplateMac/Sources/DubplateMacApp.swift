import SwiftUI
import SwiftData
import DubplateCore
import DubplateUI

/// Dubplate for Mac: the room where records get made.
@main
struct DubplateMacApp: App {
    @State private var services = AppServices.launchConfigured()

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
                // Without this the segmented picker, the switches, the progress bar,
                // the sidebar selection and every focus ring render in the system
                // accent colour — on the one surface whose palette exists to keep
                // the interface from competing with the artwork.
                .tint(DubplateColor.primaryText)
                .task { await services.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands { DubplateCommands(services: services) }

        // A preview you can leave open beside the record is worth more than a modal,
        // and a 900pt sheet does not fit the laptop most producers own.
        Window("iPhone", id: DubplateWindow.phonePreview) {
            PhonePreviewWindow()
                .environment(services)
                .environment(services.library)
                .environment(services.player)
                .environment(services.artwork)
                .environment(services.settings)
                .modelContainer(services.container)
                .tint(DubplateColor.primaryText)
        }
        .defaultSize(width: 480, height: 920)
        .keyboardShortcut("p", modifiers: [.command, .shift])

        Settings {
            MacSettingsView()
                // A Settings scene has its own root and inherits nothing from the
                // window group, so everything it could reach has to be supplied here.
                .environment(services)
                .environment(services.library)
                .environment(services.player)
                .environment(services.artwork)
                .environment(services.sync)
                .environment(services.settings)
                .modelContainer(services.container)
                .tint(DubplateColor.primaryText)
        }
    }
}

enum DubplateWindow {
    static let phonePreview = "phone-preview"
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
            Button("Show iPhone") {
                NotificationCenter.default.post(name: .dubplateTogglePreview, object: nil)
            }
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
