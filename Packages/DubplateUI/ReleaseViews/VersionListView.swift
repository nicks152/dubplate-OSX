import SwiftUI
import DubplateCore

/// Every bounce of one track.
///
/// The current one is at the top and marked; the rest are a plain list underneath.
/// No graph, no branches, no history — a producer wants to know which mix is
/// playing and how to hear the last one, and that is the whole feature.
public struct VersionListView: View {
    private let track: Track
    private let playingVersionID: UUID?
    private let onPlay: (TrackVersion) -> Void
    private let onMakeCurrent: (TrackVersion) -> Void
    private let onRename: ((TrackVersion) -> Void)?
    private let onDelete: ((TrackVersion) -> Void)?
    private let onReveal: ((TrackVersion) -> Void)?

    public init(
        track: Track,
        playingVersionID: UUID? = nil,
        onPlay: @escaping (TrackVersion) -> Void,
        onMakeCurrent: @escaping (TrackVersion) -> Void,
        onRename: ((TrackVersion) -> Void)? = nil,
        onDelete: ((TrackVersion) -> Void)? = nil,
        onReveal: ((TrackVersion) -> Void)? = nil
    ) {
        self.track = track
        self.playingVersionID = playingVersionID
        self.onPlay = onPlay
        self.onMakeCurrent = onMakeCurrent
        self.onRename = onRename
        self.onDelete = onDelete
        self.onReveal = onReveal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.l) {
            if let current = track.currentVersion {
                VStack(alignment: .leading, spacing: DubplateLayout.s) {
                    SectionHeader("Current")
                    row(for: current, isCurrent: true)
                }
            }

            let previous = track.orderedVersions.filter { $0.id != track.currentVersionID }
            if !previous.isEmpty {
                VStack(alignment: .leading, spacing: DubplateLayout.s) {
                    SectionHeader("Previous")
                    VStack(spacing: 0) {
                        ForEach(previous) { version in
                            row(for: version, isCurrent: false)
                            if version.id != previous.last?.id {
                                Divider().overlay(DubplateColor.hairline)
                            }
                        }
                    }
                }
            }
        }
        .animation(DubplateMotion.standard, value: track.currentVersionID)
    }

    private func row(for version: TrackVersion, isCurrent: Bool) -> some View {
        HStack(spacing: DubplateLayout.m) {
            Button {
                onPlay(version)
            } label: {
                Image(systemName: playingVersionID == version.id ? "speaker.wave.2.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isCurrent ? DubplateColor.accent : DubplateColor.secondaryText)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(version.displayName)")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DubplateLayout.s) {
                    Text(version.shortName)
                        .font(DubplateType.metadata)
                        .foregroundStyle(isCurrent ? DubplateColor.accent : DubplateColor.tertiaryText)
                    Text(version.listeningLabel)
                        .font(DubplateType.rowTitle)
                        .foregroundStyle(DubplateColor.primaryText)
                        .lineLimit(1)
                }
                if let detail = detailLine(for: version) {
                    Text(detail)
                        .font(DubplateType.metadata)
                        .foregroundStyle(DubplateColor.tertiaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DubplateLayout.s)

            if !isCurrent {
                Button("Make Current") { onMakeCurrent(version) }
                    .buttonStyle(DubplateQuietButtonStyle())
                    .controlSize(.small)
            }

            Menu {
                if !isCurrent {
                    Button("Make Current") { onMakeCurrent(version) }
                }
                if let onRename {
                    Button("Rename…") { onRename(version) }
                }
                if let onReveal {
                    Button("Show in Finder") { onReveal(version) }
                }
                if let onDelete {
                    Divider()
                    Button("Delete Version", role: .destructive) { onDelete(version) }
                        .disabled(track.versionCount <= 1)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DubplateColor.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(version.displayName)")
        }
        .padding(.vertical, DubplateLayout.s)
        .padding(.horizontal, DubplateLayout.m)
        .background {
            RoundedRectangle(cornerRadius: DubplateLayout.controlRadius, style: .continuous)
                .fill(isCurrent ? DubplateColor.sunken : .clear)
        }
        .accessibilityElement(children: .combine)
    }

    private func detailLine(for version: TrackVersion) -> String? {
        var parts: [String] = []
        if let asset = version.audioAsset {
            parts.append(Formatting.duration(asset.duration))
            if !asset.formatSummary.isEmpty { parts.append(asset.compactFormat) }
            if let loudness = asset.loudnessSummary { parts.append(loudness) }
        }
        if let notes = version.notes, !notes.isEmpty { parts.append(notes) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}
