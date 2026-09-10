import SwiftUI
import DubplateCore

/// Everything about one track, and nothing that is required.
///
/// Metadata in Dubplate is optional by design: a record that has only filenames
/// should still play, sync and feel finished. Fields here are quiet and unlabelled
/// until focused, so the inspector reads like a credit sheet, not a form.
public struct TrackInspectorView: View {
    @Bindable private var track: Track
    private let onCommit: () -> Void
    private let onShowVersions: () -> Void

    public init(track: Track, onCommit: @escaping () -> Void, onShowVersions: @escaping () -> Void) {
        self.track = track
        self.onCommit = onCommit
        self.onShowVersions = onShowVersions
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DubplateLayout.xl) {
                identity
                Divider().overlay(DubplateColor.hairline)
                versionSummary
                Divider().overlay(DubplateColor.hairline)
                technical
                if let notesBinding = Binding($track.notes) {
                    Divider().overlay(DubplateColor.hairline)
                    field("Notes", text: notesBinding, axis: .vertical)
                } else {
                    Button("Add a Note") {
                        track.notes = ""
                        onCommit()
                    }
                    .buttonStyle(DubplateQuietButtonStyle())
                }
            }
            .padding(DubplateLayout.xl)
        }
        .background(DubplateColor.raised)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.l) {
            field("Title", text: $track.title)
            field("Artist", text: $track.artistName)
            field("Featured", text: Binding($track.featuredArtists) ?? .constant(""), placeholder: "Nobody")

            HStack(spacing: DubplateLayout.l) {
                numberField("Track", value: $track.trackNumber)
                numberField("Disc", value: $track.discNumber)
                VStack(alignment: .leading, spacing: DubplateLayout.xs) {
                    Text("Explicit").dubplateLabelStyle()
                    Toggle("", isOn: $track.explicitFlag)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: track.explicitFlag) { _, _ in onCommit() }
                }
            }
        }
    }

    private var versionSummary: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.s) {
            SectionHeader("Current Version") {
                Button("All Versions", action: onShowVersions)
                    .buttonStyle(.plain)
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.secondaryText)
            }
            if let current = track.currentVersion {
                Text(current.displayName)
                    .font(DubplateType.rowTitle)
                    .foregroundStyle(DubplateColor.primaryText)
                    .lineLimit(2)
                Text("\(track.versionCount) version\(track.versionCount == 1 ? "" : "s")")
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            } else {
                Text("No audio yet")
                    .font(DubplateType.rowTitle)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
        }
    }

    private var technical: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.s) {
            SectionHeader("File")
            if let asset = track.currentAsset {
                Text(asset.originalFilename)
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: DubplateLayout.m) {
                    Text(asset.compactFormat)
                    Text(Formatting.duration(asset.duration))
                    if let loudness = asset.loudnessSummary {
                        Text(loudness)
                    }
                }
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
                Text(Formatting.fileSize(asset.fileSize))
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            } else {
                Text("—")
                    .font(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
        }
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        axis: Axis = .horizontal
    ) -> some View {
        VStack(alignment: .leading, spacing: DubplateLayout.xs) {
            Text(label).dubplateLabelStyle()
            TextField(placeholder, text: text, axis: axis)
                .textFieldStyle(.plain)
                .font(DubplateType.rowTitle)
                .foregroundStyle(DubplateColor.primaryText)
                .lineLimit(axis == .vertical ? 2...6 : 1)
                .padding(.vertical, DubplateLayout.s)
                .padding(.horizontal, DubplateLayout.m)
                .background(DubplateColor.sunken, in: RoundedRectangle(cornerRadius: DubplateLayout.controlRadius, style: .continuous))
                .onSubmit(onCommit)
        }
    }

    private func numberField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: DubplateLayout.xs) {
            Text(label).dubplateLabelStyle()
            TextField("", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(DubplateType.metadata)
                .frame(width: 48)
                .padding(.vertical, DubplateLayout.s)
                .padding(.horizontal, DubplateLayout.m)
                .background(DubplateColor.sunken, in: RoundedRectangle(cornerRadius: DubplateLayout.controlRadius, style: .continuous))
                .onSubmit(onCommit)
        }
    }
}
