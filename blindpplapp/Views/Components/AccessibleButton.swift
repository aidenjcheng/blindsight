import SwiftUI

struct AccessibleButton: View {
    let title: String
    let systemImage: String
    let style: ButtonVariant
    let action: () -> Void

    @State private var isPressed = false

    enum ButtonVariant {
        case primary
        case destructive
        case secondary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))

                Text(title)
                    .font(BNTheme.Font.bodyMedium)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .foregroundColor(foregroundValue)
            .background(backgroundContent)
            .clipShape(RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous))
            .overlay(borderOverlay)
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint("Double tap to activate")
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    @ViewBuilder
    private var backgroundContent: some View {
        switch style {
        case .primary:
            ZStack {
                RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
                    .fill(BNTheme.brandPrimary.opacity(0.78))
            }
            .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
        case .destructive:
            ZStack {
                RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
                    .fill(BNTheme.danger.opacity(0.72))
            }
            .shadow(color: BNTheme.danger.opacity(0.15), radius: 12, y: 6)
        case .secondary:
            ZStack {
                RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
                    .fill(Color.white.opacity(0.2))
            }
            .shadow(color: .black.opacity(0.06), radius: 10, y: 5)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: BNTheme.Radius.md, style: .continuous)
            .stroke(Color.white.opacity(style == .secondary ? 0.5 : 0.2), lineWidth: 0.5)
    }

    private var foregroundValue: Color {
        switch style {
        case .primary, .destructive: return .white
        case .secondary: return BNTheme.textPrimary
        }
    }
}
