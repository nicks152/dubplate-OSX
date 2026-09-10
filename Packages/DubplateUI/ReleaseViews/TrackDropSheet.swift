import SwiftUI
import DubplateCore

/// The question asked when a bounce lands on a track that already has audio.
///
/// The default is the one that cannot lose anything: keep the old mix, add the new
/// one, start playing it. The destructive option is present but never pre-selected.
public struct TrackDropSheet: View {
    private let filename: String
    private let track: Track
    private let suggestion: VersionMatch?
    private let onCancel: () -> Void
    private let onChoose: (TrackDropChoice) -> Void

    @State private var choice: TrackDropChoice = .recommended

    public init(
        filename: String,
        track: Track,
        suggestion: VersionMatch? = nil,
        onCancel: @escaping () -> Void,
        onChoose: @escaping (TrackDropChoice) -> Void
    ) {
        self.filename = filename
        self.track = track
        self.suggestion = suggestion
        self.onCancel = onCancel
        self.onChoose = onChoose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.xl) {
            VStack(alignment: .leading, spacing: DubplateLayout.xs) {
                Text(filename)
                    .dubplateFont(.fixed(17, weight: .medium))
                    .foregroundStyle(DubplateColor.primaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(subtitle)
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.tertiaryText)
            }

            VStack(spacing: DubplateLayout.s) {
                ForEach(TrackDropChoice.allCases) { option in
                    Button {
                        choice = option
                    } label: {
                        HStack(alignment: .top, spacing: DubplateLayout.m) {
                            Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(choice == option ? DubplateColor.accent : DubplateColor.tertiaryText)
                                .dubplateFont(.fixed(15))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .dubplateFont(DubplateType.rowTitle)
                                    .foregroundStyle(DubplateColor.primaryText)
                                Text(option.explanation)
                                    .dubplateFont(DubplateType.metadata)
                                    .foregroundStyle(DubplateColor.tertiaryText)
                            }
                            Spacer()
                        }
                        .padding(DubplateLayout.m)
                        .background {
                            RoundedRectangle(cornerRadius: DubplateLayout.controlRadius, style: .continuous)
                                .fill(choice == option ? DubplateColor.sunken : .clear)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice == option ? .isSelected : [])
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(DubplateQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                // Named after what it does, because one of these three deletes a
                // file. "Continue" is the wrong word for that in any dialog.
                Button(choice.title) { onChoose(choice) }
                    .buttonStyle(DubplateFilledButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DubplateLayout.xxl)
        .frame(width: 480)
        .background(DubplateColor.raised)
    }

    private var subtitle: String {
        if let suggestion, suggestion.isConfident {
            return "\(suggestion.reason) as \(track.displayTitle) — currently \(track.currentVersion?.shortName ?? "v1")"
        }
        return "Dropped on \(track.displayTitle) — currently \(track.currentVersion?.shortName ?? "v1")"
    }
}
