import SwiftUI
import DubplateCore
import DubplateAudio

/// What is coming next.
public struct QueueView: View {
    private let player: PlayerController
    private let onDismiss: (() -> Void)?

    public init(player: PlayerController, onDismiss: (() -> Void)? = nil) {
        self.player = player
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.l) {
            HStack {
                Text("Up Next")
                    .dubplateDisplayStyle(.inline)
                    .foregroundStyle(DubplateColor.playerPrimaryText)
                Spacer()
                if let onDismiss {
                    Button("Done", action: onDismiss)
                        .buttonStyle(.plain)
                        .dubplateFont(.fixed(13, weight: .medium))
                        .foregroundStyle(DubplateColor.playerSecondaryText)
                }
            }

            if let current = player.currentItem {
                row(current, isCurrent: true)
                Divider().overlay(.white.opacity(0.1))
            }

            if player.queue.upNext.isEmpty {
                Text("Nothing after this one.")
                    .dubplateFont(DubplateType.rowSubtitle)
                    .foregroundStyle(DubplateColor.playerSecondaryText)
                    .padding(.vertical, DubplateLayout.l)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(player.queue.upNext) { item in
                            row(item, isCurrent: false)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DubplateLayout.xl)
        .background(DubplateColor.playerGround)
    }

    private func row(_ item: PlaybackQueueItem, isCurrent: Bool) -> some View {
        Button {
            player.skip(to: item)
        } label: {
            HStack(spacing: DubplateLayout.m) {
                if isCurrent {
                    PlayingIndicator(isAnimating: player.isPlaying)
                        .frame(width: 18)
                } else {
                    Text("\(item.trackNumber)")
                        .dubplateFont(DubplateType.metadata)
                        .foregroundStyle(DubplateColor.playerSecondaryText)
                        .frame(width: 18, alignment: .trailing)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .dubplateFont(DubplateType.rowTitle)
                        .foregroundStyle(DubplateColor.playerPrimaryText)
                        .lineLimit(1)
                    Text(item.artistName)
                        .dubplateFont(DubplateType.metadata)
                        .foregroundStyle(DubplateColor.playerSecondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text(Formatting.duration(item.duration))
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.playerSecondaryText)
            }
            .padding(.vertical, DubplateLayout.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The version picker as it appears from the player: a list, a tick, and one
/// button that makes the choice permanent.
///
/// Selecting a version here plays it from the same moment the current one had
/// reached, which is how two mixes actually get compared.
public struct VersionPickerSheet: View {
    private let track: Track
    private let playingVersionID: UUID?
    private let onSelect: (TrackVersion) -> Void
    private let onSetCurrent: (TrackVersion) -> Void
    private let onDismiss: () -> Void

    public init(
        track: Track,
        playingVersionID: UUID?,
        onSelect: @escaping (TrackVersion) -> Void,
        onSetCurrent: @escaping (TrackVersion) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.track = track
        self.playingVersionID = playingVersionID
        self.onSelect = onSelect
        self.onSetCurrent = onSetCurrent
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.l) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mixes").dubplateLabelStyle(DubplateColor.playerSecondaryText)
                    Text(track.displayTitle)
                        .dubplateFont(.fixed(20, weight: .semibold))
                        .foregroundStyle(DubplateColor.playerPrimaryText)
                }
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(.plain)
                    .dubplateFont(.fixed(13, weight: .medium))
                    .foregroundStyle(DubplateColor.playerSecondaryText)
            }

            ForEach(track.orderedVersions) { version in
                // Two separate controls, side by side. A Button inside another
                // Button's label is not reliably tappable on iOS, and "Set as
                // Current" is the only committing action the phone has.
                HStack(spacing: DubplateLayout.m) {
                    Button {
                        onSelect(version)
                    } label: {
                        HStack(spacing: DubplateLayout.m) {
                            Image(systemName: "checkmark")
                                .dubplateFont(.fixed(12, weight: .semibold))
                                .foregroundStyle(DubplateColor.playerPrimaryText)
                                .opacity(playingVersionID == version.id ? 1 : 0)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(version.listeningLabel)
                                    .dubplateFont(DubplateType.rowTitle)
                                    .foregroundStyle(DubplateColor.playerPrimaryText)
                                Text(subtitle(for: version))
                                    .dubplateFont(DubplateType.metadata)
                                    .foregroundStyle(DubplateColor.playerSecondaryText)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: DubplateLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Plays this mix from the same moment")

                    if version.isCurrent {
                        Text("In the record")
                            .dubplateFont(DubplateType.label)
                            .kerning(0.5)
                            .foregroundStyle(DubplateColor.playerSecondaryText)
                    } else {
                        Button("Use This Mix") { onSetCurrent(version) }
                            .buttonStyle(.plain)
                            .dubplateFont(.fixed(11, weight: .medium))
                            .foregroundStyle(DubplateColor.playerSecondaryText)
                            .frame(minHeight: DubplateLayout.minimumTapTarget)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DubplateLayout.xl)
        .background(DubplateColor.playerGround)
    }

    private func subtitle(for version: TrackVersion) -> String {
        // The date is the point: "yesterday's mix" is how producers refer to these.
        var parts = [version.shortName, Formatting.relativeDate(version.createdAt)]
        if let asset = version.audioAsset {
            parts.append(Formatting.duration(asset.duration))
            if !asset.compactFormat.isEmpty { parts.append(asset.compactFormat) }
        }
        return parts.joined(separator: " · ")
    }
}
