import Foundation
import MediaPlayer
import DubplateCore

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What the Lock Screen, Control Centre, a car dashboard and a pair of AirPods
/// know about what is playing.
///
/// Getting this right is most of what makes an unreleased record feel released:
/// the artwork and title on the Lock Screen are the moment the illusion lands.
@MainActor
public final class NowPlayingCoordinator {

    public struct Commands {
        public var play: () -> Void = {}
        public var pause: () -> Void = {}
        public var toggle: () -> Void = {}
        public var next: () -> Void = {}
        public var previous: () -> Void = {}
        public var seek: (TimeInterval) -> Void = { _ in }
        public var skipForward: (TimeInterval) -> Void = { _ in }
        public var skipBackward: (TimeInterval) -> Void = { _ in }

        public init() {}
    }

    private var artworkCache: [UUID: MPMediaItemArtwork] = [:]
    private var lastItemID: UUID?

    public init() {}

    // MARK: - Remote commands

    public func attach(_ commands: Commands) {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { _ in
            commands.play()
            return .success
        }
        center.pauseCommand.addTarget { _ in
            commands.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            commands.toggle()
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            commands.next()
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            commands.previous()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            commands.seek(event.positionTime)
            return .success
        }

        // Wired headset buttons and car controls send skip commands on long-form
        // audio; 15 seconds matches what people expect from every other player.
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            commands.skipForward(event.interval)
            return .success
        }
        center.skipBackwardCommand.addTarget { event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            commands.skipBackward(event.interval)
            return .success
        }

        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                        center.nextTrackCommand, center.previousTrackCommand,
                        center.changePlaybackPositionCommand, center.skipForwardCommand,
                        center.skipBackwardCommand] {
            command.isEnabled = true
        }
        // Dubplate has no ratings, no likes and no radio.
        center.ratingCommand.isEnabled = false
        center.likeCommand.isEnabled = false
        center.dislikeCommand.isEnabled = false
    }

    public func detach() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
    }

    // MARK: - Now Playing info

    public func update(
        item: PlaybackQueueItem?,
        isPlaying: Bool,
        elapsed: TimeInterval,
        queuePosition: (index: Int, count: Int)?
    ) {
        let center = MPNowPlayingInfoCenter.default()
        guard let item else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            lastItemID = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artistName,
            MPMediaItemPropertyAlbumTitle: item.releaseTitle,
            MPMediaItemPropertyPlaybackDuration: item.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyAlbumTrackNumber: item.trackNumber
        ]
        if let queuePosition {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queuePosition.index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queuePosition.count
            info[MPMediaItemPropertyAlbumTrackCount] = queuePosition.count
        }
        if let artwork = artwork(for: item) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        lastItemID = item.id
    }

    /// Cheap update for scrubbing: rewrites only the moving values.
    public func updatePosition(elapsed: TimeInterval, isPlaying: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        guard var info = center.nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func artwork(for item: PlaybackQueueItem) -> MPMediaItemArtwork? {
        if let cached = artworkCache[item.releaseID] { return cached }
        guard let data = item.artworkThumbnail else { return nil }

        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        #else
        guard let image = NSImage(data: data) else { return nil }
        #endif

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        artworkCache[item.releaseID] = artwork
        return artwork
    }

    /// Drops cached artwork for a release whose cover changed.
    public func invalidateArtwork(releaseID: UUID) {
        artworkCache[releaseID] = nil
    }
}
