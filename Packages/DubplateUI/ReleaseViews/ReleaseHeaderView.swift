import SwiftUI
import DubplateCore

/// The top of a release page: artwork, title, credit, and the two buttons that
/// start the record.
///
/// The same component on both platforms, laid out side-by-side where there is width
/// and stacked where there is not — a record's identity should not change shape
/// depending on which device you opened it on.
public struct ReleaseHeaderView: View {
    public enum Layout {
        /// Artwork left, type right. Mac release page.
        case horizontal
        /// Artwork centred above the type. iPhone release page.
        case centred
    }

    @Bindable private var release: Release
    private let layout: Layout
    private let artworkEdge: CGFloat
    /// Editing belongs to the Mac. The phone shows a record; it does not rename one.
    private let isEditable: Bool
    private let onPlay: () -> Void
    private let onShuffle: () -> Void
    private let onEditArtwork: (() -> Void)?
    private let onCommit: (() -> Void)?

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case title
        case artist
    }

    public init(
        release: Release,
        layout: Layout = .horizontal,
        artworkEdge: CGFloat = 220,
        isEditable: Bool = false,
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void,
        onEditArtwork: (() -> Void)? = nil,
        onCommit: (() -> Void)? = nil
    ) {
        self.release = release
        self.layout = layout
        self.artworkEdge = artworkEdge
        self.isEditable = isEditable
        self.onPlay = onPlay
        self.onShuffle = onShuffle
        self.onEditArtwork = onEditArtwork
        self.onCommit = onCommit
    }

    public var body: some View {
        switch layout {
        case .horizontal:
            HStack(alignment: .bottom, spacing: DubplateLayout.xl) {
                artwork
                VStack(alignment: .leading, spacing: DubplateLayout.m) {
                    text(alignment: .leading)
                    buttons
                }
                Spacer(minLength: 0)
            }
        case .centred:
            VStack(spacing: DubplateLayout.l) {
                artwork
                text(alignment: .center)
                buttons
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var artwork: some View {
        ArtworkView(
            asset: release.artwork,
            title: release.title,
            cornerRadius: DubplateLayout.largeArtworkRadius
        )
        .frame(width: artworkEdge, height: artworkEdge)
        .shadow(color: .black.opacity(0.3), radius: 26, y: 12)
        .contentShape(Rectangle())
        .onTapGesture { onEditArtwork?() }
        .accessibilityAddTraits(onEditArtwork == nil ? [] : .isButton)
        .accessibilityHint(onEditArtwork == nil ? "" : "Change artwork")
    }

    private func text(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: DubplateLayout.xs) {
            Text(release.releaseType.displayName)
                .dubplateLabelStyle()

            if isEditable {
                // The title is the thing that turns a folder into a record, so it
                // is editable exactly where you read it — no dialog, no inspector.
                TextField("Untitled", text: $release.title)
                    .textFieldStyle(.plain)
                    .dubplateDisplayStyle(size: layout == .centred ? 30 : 44)
                    .foregroundStyle(DubplateColor.primaryText)
                    .focused($focusedField, equals: .title)
                    .onSubmit { commit() }

                TextField("Artist", text: $release.artistName)
                    .textFieldStyle(.plain)
                    .font(.system(size: layout == .centred ? 16 : 18, weight: .medium))
                    .foregroundStyle(DubplateColor.secondaryText)
                    .focused($focusedField, equals: .artist)
                    .onSubmit { commit() }
            } else {
                Text(release.title.isEmpty ? "Untitled" : release.title)
                    .dubplateDisplayStyle(size: layout == .centred ? 30 : 44)
                    .foregroundStyle(DubplateColor.primaryText)
                    .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)

                Text(release.artistName)
                    .font(.system(size: layout == .centred ? 16 : 18, weight: .medium))
                    .foregroundStyle(DubplateColor.secondaryText)
            }

            Text(metadataLine)
                .font(DubplateType.metadata)
                .foregroundStyle(DubplateColor.tertiaryText)
        }
        .multilineTextAlignment(alignment == .center ? .center : .leading)
        .onChange(of: focusedField) { _, newValue in
            if newValue == nil { commit() }
        }
    }

    private func commit() {
        release.updatedAt = Date()
        onCommit?()
    }

    private var buttons: some View {
        HStack(spacing: DubplateLayout.m) {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(DubplateFilledButtonStyle())
            .disabled(release.trackCount == 0)

            Button(action: onShuffle) {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(DubplateQuietButtonStyle())
            .disabled(release.trackCount < 2)
        }
        .labelStyle(.titleAndIcon)
    }

    /// The release type is already set above this line; repeating it there was a
    /// straight duplication.
    private var metadataLine: String {
        let count = release.trackCount
        var parts = ["\(count) track\(count == 1 ? "" : "s")"]
        if let year = release.year { parts.append(String(year)) }
        if release.totalDuration > 0 {
            parts.append(Formatting.longDuration(release.totalDuration))
        }
        return parts.joined(separator: " · ")
    }
}
