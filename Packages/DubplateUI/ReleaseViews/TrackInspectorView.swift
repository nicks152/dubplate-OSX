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
    @FocusState private var focusedField: String?

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
        .publishesTextEditing(focusedField != nil)
        .onChange(of: focusedField) { _, newValue in
            if newValue == nil { onCommit() }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.l) {
            field("Title", text: $track.title)
            field("Artist", text: $track.artistName)
            // Not `Binding($track.featuredArtists) ?? .constant("")`: that
            // initialiser returns nil while the optional is nil, which is every
            // track whose filename did not say "feat." — so the fallback took over
            // and the field silently discarded what was typed into it. Writing an
            // empty string back as nil keeps the model's "no features" honest.
            field(
                "Featured",
                text: Binding(
                    get: { track.featuredArtists ?? "" },
                    set: { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        track.featuredArtists = trimmed.isEmpty ? nil : newValue
                    }
                ),
                placeholder: "Nobody else on it"
            )

            HStack(alignment: .top, spacing: DubplateLayout.xl) {
                // Read-only: the sequence is the drag list, and a field that looks
                // editable but is renumbered by every repair is worse than no field.
                VStack(alignment: .leading, spacing: DubplateLayout.xs) {
                    Text("Track").dubplateLabelStyle()
                    Text("\(track.trackNumber) of \(track.release?.trackCount ?? 1)")
                        .dubplateFont(DubplateType.metadata)
                        .foregroundStyle(DubplateColor.secondaryText)
                        .help("Drag the track list to change the running order")
                }
                VStack(alignment: .leading, spacing: DubplateLayout.xs) {
                    Text("Explicit").dubplateLabelStyle()
                    // Labelled for VoiceOver even though the label is drawn above
                    // it: `Toggle("")` reads as an unnamed switch, and the Text
                    // beside it is a separate element that never gets associated.
                    Toggle("Explicit", isOn: $track.explicitFlag)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: track.explicitFlag) { _, _ in onCommit() }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var versionSummary: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.s) {
            SectionHeader("Current Mix") {
                Button("All Mixes", action: onShowVersions)
                    .buttonStyle(.plain)
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.secondaryText)
            }
            if let current = track.currentVersion {
                Text(current.displayName)
                    .dubplateFont(DubplateType.rowTitle)
                    .foregroundStyle(DubplateColor.primaryText)
                    .lineLimit(2)
                Text("\(track.versionCount) mix\(track.versionCount == 1 ? "" : "es") · \(Formatting.relativeDate(current.createdAt))")
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            } else {
                Text("No audio yet")
                    .dubplateFont(DubplateType.rowTitle)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
        }
    }

    private var technical: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.s) {
            SectionHeader("File")
            if let asset = track.currentAsset {
                Text(asset.sourceFolder.map { "\($0)/\(asset.originalFilename)" } ?? asset.originalFilename)
                    .dubplateFont(DubplateType.metadata)
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
                .dubplateFont(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
                Text(Formatting.fileSize(asset.fileSize))
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            } else {
                Text("—")
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }
        }
    }

    /// No fill and no border at rest — a hairline that lights up on focus.
    ///
    /// A persistent filled box under every value is what makes an inspector read as
    /// a database record editor, which is the one thing this pane must not be.
    private func field(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        axis: Axis = .horizontal
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).dubplateLabelStyle()
            TextField(placeholder, text: text, axis: axis)
                .textFieldStyle(.plain)
                .dubplateFont(.fixed(15))
                .foregroundStyle(DubplateColor.primaryText)
                .lineLimit(axis == .vertical ? 2...6 : 1)
                .focused($focusedField, equals: label)
                .onSubmit(onCommit)
                .padding(.bottom, 5)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(focusedField == label ? DubplateColor.primaryText : DubplateColor.hairline)
                        .frame(height: DubplateLayout.hairline)
                }
        }
        .frame(minHeight: 44, alignment: .top)
        .animation(DubplateMotion.quick, value: focusedField)
    }

}
