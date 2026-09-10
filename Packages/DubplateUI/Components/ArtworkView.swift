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
    private let artist: String
    /// `nil` means "size it from the artwork", which is almost always right.
    private let cornerRadius: CGFloat?

    @Environment(ArtworkLoader.self) private var loader
    @State private var image: DubplateImage?
    @State private var didLoad = false

    public init(
        asset: ArtworkAsset?,
        title: String,
        artist: String = "",
        cornerRadius: CGFloat? = nil
    ) {
        self.asset = asset
        self.title = title
        self.artist = artist
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
                    MonogramArtwork(title: title, artist: artist)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: radius(for: edge), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius(for: edge), style: .continuous)
                    .strokeBorder(DubplateColor.hairline, lineWidth: DubplateLayout.hairline)
            }
            .task(id: asset?.relativePath) {
                await load(edge: edge)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(image == nil ? "\(title), no artwork" : "\(title) artwork")
    }

    private func radius(for edge: CGFloat) -> CGFloat {
        cornerRadius ?? DubplateLayout.artworkRadius(forEdge: edge)
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

/// The cover a record has before anyone has made one.
///
/// Every record has this on day one, so it has to be a cover rather than an
/// apology. The title is set large — the mark, not a caption — with the credit
/// under it, on a ground derived from the title itself: barely-there chroma, so
/// four unmade records on a shelf are four different objects without the interface
/// introducing a palette of its own.
public struct MonogramArtwork: View {
    private let title: String
    private let artist: String

    public init(title: String, artist: String = "") {
        self.title = title
        self.artist = artist
    }

    public var body: some View {
        GeometryReader { geometry in
            let edge = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: shades,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // Below this the type is a smear rather than a mark — a sidebar
                // thumbnail and a mini-player cover show the ground only.
                if edge >= 64 {
                    VStack(alignment: .leading, spacing: edge * 0.02) {
                        Text(displayTitle)
                            .font(.system(size: edge * 0.15, weight: .semibold))
                            .kerning(edge * -0.0033)
                            .textCase(.uppercase)
                            .foregroundStyle(.white)
                            .lineLimit(3)
                        if !artist.isEmpty {
                            Text(artist)
                                .font(.system(size: edge * 0.045, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .padding(edge * 0.09)
                }
            }
        }
    }

    private var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// A stable hash of the title picks the ground. Not `hashValue`, which is seeded
    /// per process and would give a record a different cover on every launch.
    private var shades: [Color] {
        var hash: UInt64 = 5381
        for byte in displayTitle.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let hue = Double(hash % 360) / 360
        return [
            Color(hue: hue, saturation: 0.12, brightness: 0.30),
            Color(hue: hue, saturation: 0.14, brightness: 0.13)
        ]
    }
}
