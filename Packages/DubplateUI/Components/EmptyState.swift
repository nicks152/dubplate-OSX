import SwiftUI
import DubplateCore

/// What a screen says when there is nothing on it yet.
///
/// No illustration, no icon: a line of type and the one thing to do next. Empty
/// states are where a product's voice is most audible, so Dubplate's are written
/// like an instruction from someone who has done this before.
public struct EmptyState: View {
    private let headline: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        headline: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.headline = headline
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: DubplateLayout.m) {
            Text(headline)
                .dubplateFont(.fixed(20, weight: .semibold))
                .kerning(-0.2)
                .foregroundStyle(DubplateColor.primaryText)
            Text(message)
                .dubplateFont(DubplateType.rowSubtitle)
                .foregroundStyle(DubplateColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(DubplateFilledButtonStyle())
                    .padding(.top, DubplateLayout.s)
            }
        }
        .padding(DubplateLayout.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// The one filled button in the product.
public struct DubplateFilledButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dubplateFont(.fixed(13, weight: .medium))
            .foregroundStyle(DubplateColor.ground)
            .padding(.horizontal, DubplateLayout.l)
            .frame(height: 32)
            .background(DubplateColor.primaryText.opacity(isEnabled ? 1 : 0.4), in: Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(DubplateMotion.respecting(reduceMotion, DubplateMotion.quick), value: configuration.isPressed)
    }
}

/// The quiet one next to it.
public struct DubplateQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dubplateFont(.fixed(13, weight: .medium))
            .foregroundStyle(DubplateColor.primaryText.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, DubplateLayout.l)
            .frame(height: 32)
            .background(DubplateColor.sunken, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A titled band above a list or grid.
public struct SectionHeader<Trailing: View>: View {
    private let title: String
    private let trailing: Trailing

    public init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .dubplateLabelStyle(DubplateColor.secondaryText)
            Spacer()
            trailing
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// The line Dubplate uses to report an error, everywhere.
public struct ErrorBanner: View {
    private let error: DubplateError
    private let onRetry: (() -> Void)?
    private let onDismiss: () -> Void

    public init(error: DubplateError, onRetry: (() -> Void)? = nil, onDismiss: @escaping () -> Void) {
        self.error = error
        self.onRetry = onRetry
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DubplateLayout.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title)
                    .dubplateFont(.fixed(13, weight: .medium))
                    .foregroundStyle(DubplateColor.primaryText)
                Text(subject)
                    .dubplateFont(DubplateType.metadata)
                    .foregroundStyle(DubplateColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DubplateLayout.s)
            if let onRetry, let retryTitle = error.retryTitle {
                Button(retryTitle, action: onRetry)
                    .buttonStyle(DubplateQuietButtonStyle())
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .dubplateFont(.fixed(11, weight: .semibold))
                    .foregroundStyle(DubplateColor.secondaryText)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(DubplateLayout.l)
        .background(DubplateColor.raised, in: RoundedRectangle(cornerRadius: DubplateLayout.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DubplateLayout.controlRadius, style: .continuous)
                .strokeBorder(DubplateColor.hairline)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(error.title). \(subject)")
    }

    private var subject: String {
        if let name = error.subject {
            return "\(name) — \(error.detail)"
        }
        return error.detail
    }
}

/// A line that says what just happened, and then goes away.
///
/// Silence after a drop is what makes a bounce that was recognised as a duplicate
/// indistinguishable from one that was lost.
public struct Toast: View {
    private let message: String
    private let onDismiss: () -> Void

    public init(message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: DubplateLayout.m) {
            Text(message)
                .dubplateFont(.fixed(13))
                .foregroundStyle(DubplateColor.primaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .dubplateFont(.fixed(10, weight: .semibold))
                    .foregroundStyle(DubplateColor.tertiaryText)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, DubplateLayout.l)
        .padding(.trailing, DubplateLayout.xs)
        .padding(.vertical, DubplateLayout.s)
        .background(DubplateColor.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(DubplateColor.hairline))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .task {
            // Announced, not just drawn. This is the product's only channel for
            // "here is what that drop did", and it comes and goes in six seconds —
            // a VoiceOver user was never told at all.
            AccessibilityNotification.Announcement(message).post()
            try? await Task.sleep(for: .seconds(6))
            onDismiss()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
