import SwiftUI
import DubplateCore
import DubplateAudio

/// The playhead.
///
/// When a waveform has been measured it is drawn behind the progress, because a
/// producer reads the shape of a mix faster than they read a number. When it has
/// not, the bar is a plain line rather than a fake waveform.
public struct ScrubBar: View {
    private let progress: Double
    private let elapsed: TimeInterval
    private let duration: TimeInterval
    private let peaks: Data?
    private let tint: Color
    private let onScrubStart: (TimeInterval) -> Void
    private let onScrubChange: (TimeInterval) -> Void
    private let onScrubEnd: () -> Void

    @State private var isScrubbing = false
    /// Peak bytes expanded to bar heights, once per waveform rather than once per
    /// frame. The bar redraws several times a second while a record plays and on
    /// every touch event while a finger is on it; decoding four hundred peaks
    /// inside `body` meant doing that work sixty times a second to draw the same
    /// shape.
    @State private var heights: [Double] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        progress: Double,
        elapsed: TimeInterval,
        duration: TimeInterval,
        peaks: Data? = nil,
        tint: Color = DubplateColor.playerPrimaryText,
        onScrubStart: @escaping (TimeInterval) -> Void,
        onScrubChange: @escaping (TimeInterval) -> Void,
        onScrubEnd: @escaping () -> Void
    ) {
        self.progress = progress
        self.elapsed = elapsed
        self.duration = duration
        self.peaks = peaks
        self.tint = tint
        self.onScrubStart = onScrubStart
        self.onScrubChange = onScrubChange
        self.onScrubEnd = onScrubEnd
    }

    public var body: some View {
        VStack(spacing: DubplateLayout.s) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    track(width: geometry.size.width, filled: false)
                    track(width: geometry.size.width, filled: true)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: max(0, geometry.size.width * progress))
                        }
                }
                .frame(height: barHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: geometry.size.width))
            }
            .frame(height: isScrubbing ? 34 : 26)
            .animation(DubplateMotion.respecting(reduceMotion, DubplateMotion.quick), value: isScrubbing)

            HStack {
                Text(Formatting.duration(elapsed))
                Spacer()
                Text("-" + Formatting.duration(max(0, duration - elapsed)))
            }
            .dubplateFont(DubplateType.metadata)
            .foregroundStyle(tint.opacity(0.55))
        }
        .task(id: peaks) {
            heights = peaks.map { WaveformGenerator.heights(from: $0) } ?? []
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Formatting.duration(elapsed)) of \(Formatting.duration(duration))")
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = 15
            switch direction {
            case .increment: onScrubChange(min(duration, elapsed + step))
            case .decrement: onScrubChange(max(0, elapsed - step))
            @unknown default: break
            }
            onScrubEnd()
        }
    }

    private var barHeight: CGFloat {
        heights.isEmpty ? (isScrubbing ? 6 : 4) : (isScrubbing ? 34 : 26)
    }

    @ViewBuilder
    private func track(width: CGFloat, filled: Bool) -> some View {
        let color = filled ? tint : tint.opacity(0.22)
        if !heights.isEmpty {
            WaveformShape(heights: heights).fill(color)
        } else {
            Capsule().fill(color)
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let time = time(at: value.location.x, width: width)
                if !isScrubbing {
                    isScrubbing = true
                    onScrubStart(time)
                } else {
                    onScrubChange(time)
                }
            }
            .onEnded { _ in
                isScrubbing = false
                onScrubEnd()
            }
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(0, Double(x / width)), 1) * duration
    }
}

/// Draws stored peak data as a symmetrical bar waveform.
struct WaveformShape: Shape {
    let heights: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !heights.isEmpty, rect.width > 0 else { return path }

        let barWidth: CGFloat = 2
        let spacing: CGFloat = 1
        let stride = barWidth + spacing
        let count = max(1, Int(rect.width / stride))
        let midY = rect.midY

        for index in 0..<count {
            let sample = heights[min(heights.count - 1, index * heights.count / count)]
            let height = max(1.5, CGFloat(sample) * rect.height)
            let x = CGFloat(index) * stride
            path.addRoundedRect(
                in: CGRect(x: x, y: midY - height / 2, width: barWidth, height: height),
                cornerSize: CGSize(width: 1, height: 1)
            )
        }
        return path
    }
}
