import SwiftUI
import SwiftData
import DubplateCore
import DubplateUI

/// Dubplate for iPhone: the record, out in the world.
@main
struct DubplateiOSApp: App {
    @State private var services = AppServices.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .environment(services)
                .environment(services.library)
                .environment(services.player)
                .environment(services.artwork)
                .environment(services.sync)
                .environment(services.settings)
                .modelContainer(services.container)
                .preferredColorScheme(services.settings.appearance.colorScheme)
                .tint(DubplateColor.primaryText)
                .task { await services.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the foreground is the moment to look for anything the
            // Mac sent while the phone was in a pocket.
            if phase == .active {
                Task { await services.sync.syncNow() }
            }
        }
    }
}
