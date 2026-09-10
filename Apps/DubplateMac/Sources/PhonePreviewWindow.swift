import SwiftUI
import DubplateAudio
import DubplateCore
import DubplateUI

/// The phone preview, in its own window.
///
/// Its own window rather than a sheet: a producer wants to see the record the way a
/// listener will *while* they are sequencing it, and a modal that blocks the track
/// list is the opposite of that. It is also the only shape that fits a laptop.
struct PhonePreviewWindow: View {
    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(DubplateSettings.self) private var settings

    @State private var mode: PreviewMode = .stream

    var body: some View {
        DevicePreviewView(
            player: player,
            artwork: currentArtwork,
            canvas: currentCanvas,
            mode: $mode
        )
        .onAppear { mode = settings.defaultPreviewMode }
        .navigationTitle("iPhone")
    }

    private var currentArtwork: ArtworkAsset? {
        guard let releaseID = player.currentItem?.releaseID else { return nil }
        return library.release(id: releaseID)?.artwork
    }

    private var currentCanvas: MotionSource? {
        guard let trackID = player.currentItem?.trackID,
              let track = library.track(id: trackID)
        else {
            return nil
        }
        if let canvas = track.canvas { return services.motionSource(for: canvas) }
        return track.release?.animatedArtwork.flatMap { services.motionSource(for: $0) }
    }
}
