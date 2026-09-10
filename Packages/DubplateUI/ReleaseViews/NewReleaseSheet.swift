import SwiftUI
import DubplateCore

/// Making a record.
///
/// Four steps, all of them skippable after the first two. The target is under
/// thirty seconds from "I have bounces" to "I am listening", so nothing here asks
/// for anything Dubplate can work out or do without.
public struct NewReleaseSheet: View {
    public struct Result {
        public var title: String
        public var artistName: String
        public var type: ReleaseType
        public var artworkURL: URL?
        public var audioURLs: [URL]
    }

    private let defaultArtistName: String
    private let onCancel: () -> Void
    private let onCreate: (Result) -> Void

    @State private var type: ReleaseType = .album
    /// Once someone picks a type, Dubplate stops guessing at it.
    @State private var typeWasChosen = false
    @State private var title = ""
    @State private var artistName = ""
    @State private var artworkURL: URL?
    @State private var audioURLs: [URL] = []
    @State private var isTargetedForArtwork = false
    @State private var isTargetedForAudio = false
    @FocusState private var titleFocused: Bool

    public init(
        defaultArtistName: String,
        onCancel: @escaping () -> Void,
        onCreate: @escaping (Result) -> Void
    ) {
        self.defaultArtistName = defaultArtistName
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.xl) {
            Text("New Release")
                .dubplateDisplayStyle(.screen)
                .foregroundStyle(DubplateColor.primaryText)

            typePicker
            names

            HStack(alignment: .top, spacing: DubplateLayout.l) {
                artworkWell
                audioWell
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(DubplateQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(
                        Result(
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            artistName: artistName.trimmingCharacters(in: .whitespacesAndNewlines),
                            type: type,
                            artworkURL: artworkURL,
                            audioURLs: audioURLs
                        )
                    )
                }
                .buttonStyle(DubplateFilledButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DubplateLayout.xxl)
        .frame(width: 560)
        .background(DubplateColor.raised)
        .onAppear {
            artistName = defaultArtistName
            titleFocused = true
        }
    }

    private var typePicker: some View {
        HStack(spacing: DubplateLayout.s) {
            ForEach(ReleaseType.allCases, id: \.self) { option in
                Button {
                    type = option
                    typeWasChosen = true
                } label: {
                    Text(option.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, DubplateLayout.l)
                        .frame(height: 30)
                        .background(
                            Capsule().fill(type == option ? DubplateColor.primaryText : DubplateColor.sunken)
                        )
                        .foregroundStyle(type == option ? DubplateColor.ground : DubplateColor.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(type == option ? .isSelected : [])
            }
        }
    }

    private var names: some View {
        VStack(alignment: .leading, spacing: DubplateLayout.m) {
            TextField("Release title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .medium))
                .focused($titleFocused)
            Divider().overlay(DubplateColor.hairline)
            TextField("Artist", text: $artistName)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(DubplateColor.secondaryText)
            Divider().overlay(DubplateColor.hairline)
        }
    }

    private var artworkWell: some View {
        DropWell(
            title: artworkURL == nil ? "Drop artwork" : (artworkURL?.lastPathComponent ?? ""),
            detail: "JPEG, PNG or HEIC",
            isTargeted: isTargetedForArtwork,
            height: 132
        ) {
            if let artworkURL {
                ArtworkView(asset: nil, title: artworkURL.deletingPathExtension().lastPathComponent)
                    .frame(width: 96, height: 96)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = DroppedFiles.expand(urls)
            guard let match = files.first(where: { FilenameParser.isImage($0.lastPathComponent) }) else {
                return false
            }
            artworkURL = match
            return true
        } isTargeted: { isTargetedForArtwork = $0 }
    }

    private var audioWell: some View {
        DropWell(
            title: audioURLs.isEmpty ? "Drop bounces" : "\(audioURLs.count) file\(audioURLs.count == 1 ? "" : "s")",
            detail: audioURLs.isEmpty
                ? "Drop the whole bounce folder — Dubplate will find the audio and the cover"
                : "Dubplate will sequence them for you",
            isTargeted: isTargetedForAudio,
            height: 132
        ) {
            EmptyView()
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = DroppedFiles.expand(urls)
            let audio = files.filter { FilenameParser.isAudio($0.lastPathComponent) }
            // One well that routes by type, so a folder containing the bounces and
            // the cover is a single drag.
            if artworkURL == nil {
                artworkURL = files.first { FilenameParser.isImage($0.lastPathComponent) }
            }
            guard !audio.isEmpty else { return artworkURL != nil }
            audioURLs.append(contentsOf: audio)
            if title.trimmingCharacters(in: .whitespaces).isEmpty,
               let first = audio.first {
                // A folder of bounces usually knows what the record is called.
                title = first.deletingLastPathComponent().lastPathComponent
            }
            if !typeWasChosen {
                type = ReleaseType.inferred(fromTrackCount: audioURLs.count)
            }
            return true
        } isTargeted: { isTargetedForAudio = $0 }
    }
}

/// The dashed area everything gets dropped on.
public struct DropWell<Content: View>: View {
    private let title: String
    private let detail: String
    private let isTargeted: Bool
    private let height: CGFloat
    private let content: Content

    public init(
        title: String,
        detail: String,
        isTargeted: Bool,
        height: CGFloat = 120,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.isTargeted = isTargeted
        self.height = height
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: DubplateLayout.s) {
            content
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DubplateColor.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .padding(DubplateLayout.m)
        .background {
            RoundedRectangle(cornerRadius: DubplateLayout.controlRadius, style: .continuous)
                .fill(isTargeted ? DubplateColor.sunken : DubplateColor.sunken.opacity(0.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: DubplateLayout.controlRadius, style: .continuous)
                .strokeBorder(
                    isTargeted ? DubplateColor.accent.opacity(0.6) : DubplateColor.hairline,
                    style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [] : [4, 4])
                )
        }
        .animation(DubplateMotion.quick, value: isTargeted)
    }
}
