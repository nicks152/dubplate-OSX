import SwiftUI
import DubplateCore

/// One line of a track list.
///
/// Number, title, duration. Everything else — versions, format, availability —
/// only appears when it has something to say, because a record's track list should
/// read like a record's track list.
public struct TrackRow: View {
    private let track: Track
    private let isCurrent: Bool
    private let isPlaying: Bool
    private let showsArtwork: Bool
    private let playingVersionID: UUID?
    private let onPlay: () -> Void
    private let onShowVersions: (() -> Void)?

    @State private var isHovering = false

    public init(
        track: Track,
        isCurrent: Bool = false,
        isPlaying: Bool = false,
        showsArtwork: Bool = false,
        playingVersionID: UUID? = nil,
        onPlay: @escaping () -> Void,
        onShowVersions: (() -> Void)? = nil
    ) {
        self.track = track
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.showsArtwork = showsArtwork
        self.playingVersionID = playingVersionID
        self.onPlay = onPlay
        self.onShowVersions = onShowVersions
    }

    public var body: some View {
        HStack(spacing: DubplateLayout.m) {
            leading
                .frame(width: 26, alignment: .center)

            if showsArtwork {
                ArtworkView(asset: track.release?.artwork, title: track.release?.title ?? track.displayTitle)
                    .frame(width: 38, height: 38)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DubplateLayout.s) {
                    Text(track.displayTitle)
                        .font(DubplateType.rowTitle)
                        .foregroundStyle(isCurrent ? DubplateColor.accent : DubplateColor.primaryText)
                        .lineLimit(1)
                    if track.explicitFlag {
                        ExplicitBadge()
                    }
                }
                if let secondary {
                    Text(secondary)
                        .font(DubplateType.metadata)
                        .foregroundStyle(DubplateColor.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DubplateLayout.s)

            if track.versionCount > 1 {
                let pill = VersionPill(
                    count: track.versionCount,
                    label: displayedVersion?.shortName ?? "",
                    isAuditioning: isAuditioning
                )
                if let onShowVersions {
                    Button(action: onShowVersions) { pill }
                        .buttonStyle(.plain)
                } else {
                    pill
                }
            }

            AvailabilityBadge(state: track.availability)

            Text(Formatting.duration(track.duration))
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .frame(minHeight: DubplateLayout.trackRowHeight)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var leading: some View {
        if isPlaying {
            PlayingIndicator()
        } else if isHovering {
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DubplateColor.primaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.displayTitle)")
        } else {
            Text("\(track.trackNumber)")
                .font(DubplateType.metadata)
                .foregroundStyle(isCurrent ? DubplateColor.accent : DubplateColor.tertiaryText)
        }
    }

    /// While a previous mix is being auditioned the row must say so — otherwise you
    /// walk away believing the record now sounds like what you just heard.
    private var isAuditioning: Bool {
        guard let playingVersionID, isCurrent else { return false }
        return playingVersionID != track.currentVersionID
    }

    private var displayedVersion: TrackVersion? {
        guard let playingVersionID, isCurrent,
              let playing = (track.versions ?? []).first(where: { $0.id == playingVersionID })
        else {
            return track.currentVersion
        }
        return playing
    }

    private var secondary: String? {
        var parts: [String] = []
        if isAuditioning, let label = displayedVersion?.listeningLabel {
            parts.append("Hearing \(label)")
        }
        if let feature = track.featureLine { parts.append(feature) }
        if let explanation = track.availability.listenerExplanation { parts.append(explanation) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        var parts = ["Track \(track.trackNumber)", track.displayTitle, Formatting.duration(track.duration)]
        if track.versionCount > 1 {
            parts.append("\(track.versionCount) versions")
        }
        if let explanation = track.availability.listenerExplanation {
            parts.append(explanation)
        }
        return parts.joined(separator: ", ")
    }
}

/// "v5 · 4" — the current version and how many there are.
/// "4 mixes" — plain language rather than version-control notation, on a surface
/// that is meant to read like a track list.
public struct VersionPill: View {
    private let count: Int
    private let label: String
    private let isAuditioning: Bool

    public init(count: Int, label: String, isAuditioning: Bool = false) {
        self.count = count
        self.label = label
        self.isAuditioning = isAuditioning
    }

    public var body: some View {
        Text("\(count) mixes")
            .font(DubplateType.label)
            .kerning(0.4)
            .foregroundStyle(isAuditioning ? DubplateColor.ground : DubplateColor.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isAuditioning ? DubplateColor.accent : DubplateColor.sunken, in: Capsule())
            .accessibilityLabel("\(count) mixes, currently \(label)")
            .accessibilityHint("Shows every mix of this track")
    }
}

public struct ExplicitBadge: View {
    public init() {}

    public var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DubplateColor.ground)
            .frame(width: 13, height: 13)
            .background(DubplateColor.tertiaryText, in: RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            .accessibilityLabel("Explicit")
    }
}

/// Says nothing at all when the audio is simply there, which is almost always.
public struct AvailabilityBadge: View {
    private let state: AvailabilityState

    public init(state: AvailabilityState) {
        self.state = state
    }

    public var body: some View {
        switch state {
        case .local, .available:
            EmptyView()
        case .downloading:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Downloading")
        case .cloudOnly:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12))
                .foregroundStyle(DubplateColor.tertiaryText)
                .accessibilityLabel("Available on your Mac")
        case .missing, .error:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(DubplateColor.alert)
                .accessibilityLabel(state == .missing ? "File not found" : "Couldn’t download")
        }
    }
}
