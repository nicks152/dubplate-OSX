import SwiftUI
import AVFoundation
import DubplateCore

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A silent, looping video used for animated artwork and track canvases.
///
/// `AVPlayerLooper` rather than restarting on the end notification, so the loop has
/// no seam. The source's own audio is always muted: whatever is on that video is not
/// what the person is listening to.
public struct LoopingVideoView: View {
    private let url: URL
    private let startTime: TimeInterval
    private let loopDuration: TimeInterval

    public init(url: URL, startTime: TimeInterval = 0, loopDuration: TimeInterval = 0) {
        self.url = url
        self.startTime = startTime
        self.loopDuration = loopDuration
    }

    public var body: some View {
        LoopingVideoRepresentable(url: url, startTime: startTime, loopDuration: loopDuration)
            .accessibilityHidden(true)
    }
}

#if os(iOS)
struct LoopingVideoRepresentable: UIViewRepresentable {
    let url: URL
    let startTime: TimeInterval
    let loopDuration: TimeInterval

    func makeUIView(context: Context) -> LoopingVideoPlatformView {
        LoopingVideoPlatformView(url: url, startTime: startTime, loopDuration: loopDuration)
    }

    func updateUIView(_ view: LoopingVideoPlatformView, context: Context) {
        view.update(url: url, startTime: startTime, loopDuration: loopDuration)
    }

    static func dismantleUIView(_ view: LoopingVideoPlatformView, coordinator: ()) {
        view.tearDown()
    }
}
#else
struct LoopingVideoRepresentable: NSViewRepresentable {
    let url: URL
    let startTime: TimeInterval
    let loopDuration: TimeInterval

    func makeNSView(context: Context) -> LoopingVideoPlatformView {
        LoopingVideoPlatformView(url: url, startTime: startTime, loopDuration: loopDuration)
    }

    func updateNSView(_ view: LoopingVideoPlatformView, context: Context) {
        view.update(url: url, startTime: startTime, loopDuration: loopDuration)
    }

    static func dismantleNSView(_ view: LoopingVideoPlatformView, coordinator: ()) {
        view.tearDown()
    }
}
#endif

#if os(iOS)
public final class LoopingVideoPlatformView: UIView {
    public override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var looper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private var currentURL: URL?

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    init(url: URL, startTime: TimeInterval, loopDuration: TimeInterval) {
        super.init(frame: .zero)
        update(url: url, startTime: startTime, loopDuration: loopDuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(url: URL, startTime: TimeInterval, loopDuration: TimeInterval) {
        guard url != currentURL else { return }
        currentURL = url
        let item = LoopingVideoConfiguration.makeItem(url: url, startTime: startTime, loopDuration: loopDuration)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player
        playerLayer?.player = player
        playerLayer?.videoGravity = .resizeAspectFill
        player.play()
    }

    func tearDown() {
        queuePlayer?.pause()
        looper?.disableLooping()
        playerLayer?.player = nil
        queuePlayer = nil
        looper = nil
    }
}
#else
public final class LoopingVideoPlatformView: NSView {
    private var looper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?
    private var playerLayer: AVPlayerLayer?
    private var currentURL: URL?

    init(url: URL, startTime: TimeInterval, loopDuration: TimeInterval) {
        super.init(frame: .zero)
        wantsLayer = true
        let playerLayer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspectFill
        layer = playerLayer
        self.playerLayer = playerLayer
        update(url: url, startTime: startTime, loopDuration: loopDuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

    func update(url: URL, startTime: TimeInterval, loopDuration: TimeInterval) {
        guard url != currentURL else { return }
        currentURL = url
        let item = LoopingVideoConfiguration.makeItem(url: url, startTime: startTime, loopDuration: loopDuration)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: player, templateItem: item)
        queuePlayer = player
        playerLayer?.player = player
        player.play()
    }

    func tearDown() {
        queuePlayer?.pause()
        looper?.disableLooping()
        playerLayer?.player = nil
        queuePlayer = nil
        looper = nil
    }
}
#endif

enum LoopingVideoConfiguration {
    /// Builds the looped item, applying a trim when one was set.
    static func makeItem(url: URL, startTime: TimeInterval, loopDuration: TimeInterval) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        if startTime > 0 {
            item.reversePlaybackEndTime = CMTime(seconds: startTime, preferredTimescale: 600)
        }
        if loopDuration > 0 {
            item.forwardPlaybackEndTime = CMTime(
                seconds: startTime + loopDuration,
                preferredTimescale: 600
            )
        }
        return item
    }
}
