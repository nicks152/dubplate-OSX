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
    private let playingVersionID: UUID?
    private let onPlay: () -> Void
    private let onShowVersions: (() -> Void)?

    @State private var isHovering = false

    public init(
        track: Track,
        isCurrent: Bool = false,
        isPlaying: Bool = false,
        playingVersionID: UUID? = nil,
        onPlay: @escaping () -> Void,
        onShowVersions: (() -> Void)? = nil
    ) {
        self.track = track
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.playingVersionID = playingVersionID
        self.onPlay = onPlay
        self.onShowVersions = onShowVersions
    }

    public var body: some View {
        HStack(spacing: 14) {
            // Right-aligned monospaced digits, so 1 and 10 share an edge beside a
            // hard-aligned title column.
            leading
                .frame(width: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DubplateLayout.s) {
                    Text(track.displayTitle)
                        .dubplateFont(DubplateType.rowTitle)
                        .foregroundStyle(isCurrent ? DubplateColor.accent : DubplateColor.primaryText)
                        .lineLimit(1)
                    if track.explicitFlag {
                        ExplicitBadge()
                    }
                }
                if let secondary {
                    Text(secondary)
                        .dubplateFont(DubplateType.metadata)
                        .foregroundStyle(DubplateColor.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DubplateLayout.s)

            if track.versionCount > 1 {
                VersionPill(
                    count: track.versionCount,
                    currentLabel: displayedVersion?.listeningLabel ?? "",
                    isAuditioning: isAuditioning
                )
            }

            AvailabilityBadge(state: track.availability)

            Text(Formatting.duration(track.duration))
                .dubplateFont(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
                .frame(minWidth: 40, alignment: .trailing)

            // Reserved on every row, so a row with mixes does not pull its duration
            // inboard of the rows above and below it.
            if let onShowVersions {
                Button(action: onShowVersions) {
                    Image(systemName: "ellipsis")
                        .dubplateFont(.fixed(13, weight: .semibold))
                        .foregroundStyle(DubplateColor.tertiaryText)
                        .frame(width: DubplateLayout.minimumTapTarget, height: DubplateLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(track.versionCount > 1 ? 1 : 0)
                .allowsHitTesting(track.versionCount > 1)
                .accessibilityLabel("Mixes of \(track.displayTitle)")
                .accessibilityHidden(track.versionCount <= 1)
            }
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
                    .dubplateFont(.fixed(11))
                    .foregroundStyle(DubplateColor.primaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.displayTitle)")
        } else {
            Text("\(track.trackNumber)")
                .dubplateFont(DubplateType.metadata)
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
            parts.append("\(track.versionCount) mixes")
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
    /// Not drawn — spoken. The pill says how many; VoiceOver says which.
    private let currentLabel: String
    private let isAuditioning: Bool

    public init(count: Int, currentLabel: String = "", isAuditioning: Bool = false) {
        self.count = count
        self.currentLabel = currentLabel
        self.isAuditioning = isAuditioning
    }

    public var body: some View {
        Text("\(count) mixes")
            .dubplateFont(DubplateType.label)
            .kerning(0.4)
            .foregroundStyle(isAuditioning ? DubplateColor.ground : DubplateColor.secondaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isAuditioning ? DubplateColor.accent : DubplateColor.sunken, in: Capsule())
            .accessibilityLabel("\(count) mixes, currently \(currentLabel)")
            .accessibilityHint("Shows every mix of this track")
    }
}

public struct ExplicitBadge: View {
    public init() {}

    public var body: some View {
        Text("E")
            .dubplateFont(.fixed(9, weight: .semibold))
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
                .dubplateFont(.fixed(12))
                .foregroundStyle(DubplateColor.tertiaryText)
                .accessibilityLabel(AvailabilityState.elsewhereDescription)
        case .missing, .error:
            Image(systemName: "exclamationmark.circle")
                .dubplateFont(.fixed(12))
                .foregroundStyle(DubplateColor.alert)
                .accessibilityLabel(state == .missing ? "File not found" : "Couldn’t download")
        }
    }
}
