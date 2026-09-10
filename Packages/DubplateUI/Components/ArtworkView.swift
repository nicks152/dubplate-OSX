import SwiftUI
import DubplateCore

/// A square cover, at whatever size it is given.
///
/// When there is no artwork the placeholder is not an icon: it is the release title
/// set on a ground derived from the title itself, so an artwork grid of covers that
/// have not been made yet still reads as a shelf of records.
public struct ArtworkView: View {
    private let asset: ArtworkAsset?
    private let title: String
    private let cornerRadius: CGFloat

    @Environment(ArtworkLoader.self) private var loader
    @State private var image: DubplateImage?
    @State private var didLoad = false

    public init(asset: ArtworkAsset?, title: String, cornerRadius: CGFloat = DubplateLayout.artworkRadius) {
        self.asset = asset
        self.title = title
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        GeometryReader { geometry in
            let edge = max(geometry.size.width, geometry.size.height)
            ZStack {
                if let image {
                    Image(dubplate: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    MonogramArtwork(title: title)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: asset?.relativePath) {
                await load(edge: edge)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DubplateColor.hairline, lineWidth: DubplateLayout.hairline)
        }
        .accessibilityLabel(image == nil ? "\(title), no artwork" : "\(title) artwork")
    }

    private func load(edge: CGFloat) async {
        if let cached = loader.cachedImage(for: asset, edge: edge) {
            image = cached
            didLoad = true
            return
        }
        let loaded = await loader.image(for: asset, edge: edge)
        withAnimation(didLoad ? DubplateMotion.quick : nil) {
            image = loaded
        }
        didLoad = true
    }
}

/// The placeholder cover.
///
/// Two greys chosen deterministically from the title, so the same record always
/// looks the same, and the title itself as the only mark.
public struct MonogramArtwork: View {
    private let title: String

    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        GeometryReader { geometry in
            let edge = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: shades,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Text(displayTitle)
                    .font(.system(size: max(9, edge * 0.088), weight: .semibold))
                    .kerning(edge * 0.006)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .padding(edge * 0.08)
            }
        }
    }

    private var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// A stable hash of the title picks the pair. Not `hashValue`, which is seeded
    /// per process and would change the cover on every launch.
    private var shades: [Color] {
        var hash: UInt64 = 5381
        for byte in displayTitle.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let base = Double(hash % 26) / 100 + 0.10
        return [
            Color(white: base + 0.16),
            Color(white: base)
        ]
    }
}
