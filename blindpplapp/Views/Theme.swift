import SwiftUI

enum BNTheme {

    // MARK: - Colors

    static let textPrimary = Color.black
    static let textSecondary = Color(red: 0.30, green: 0.30, blue: 0.32)
    static let textTertiary = Color(red: 0.50, green: 0.50, blue: 0.52)

    static let brandPrimary = Color(red: 0.22, green: 0.22, blue: 0.24)
    static let brandDeep = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let brandAccent = Color(red: 0.35, green: 0.35, blue: 0.40)

    static let danger = Color.red
    static let dangerSubtle = Color.red.opacity(0.12)
    static let warning = Color.orange
    static let warningSubtle = Color.orange.opacity(0.12)
    static let success = Color.green
    static let successSubtle = Color.green.opacity(0.12)

    static let pageBg = Color(red: 0.955, green: 0.955, blue: 0.96)
    static let cardBorder = Color.white.opacity(0.7)
    static let cardBorderBottom = Color.black.opacity(0.06)

    // MARK: - Typography

    enum Font {
        static let heroTitle = SwiftUI.Font.system(size: 34, weight: .bold, design: .rounded)
        static let heroSubtitle = SwiftUI.Font.system(size: 15, weight: .medium, design: .rounded)
        static let sectionTitle = SwiftUI.Font.system(size: 20, weight: .semibold, design: .rounded)
        static let bodyMedium = SwiftUI.Font.system(size: 16, weight: .medium, design: .rounded)
        static let bodyRegular = SwiftUI.Font.system(size: 16, weight: .regular, design: .rounded)
        static let caption = SwiftUI.Font.system(size: 13, weight: .medium, design: .rounded)
        static let captionSmall = SwiftUI.Font.system(size: 11, weight: .medium, design: .rounded)
        static let mono = SwiftUI.Font.system(size: 14, weight: .medium, design: .monospaced)
    }

    // MARK: - Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    // MARK: - Corner Radii

    enum Radius {
        static let sm: CGFloat = 12
        static let md: CGFloat = 18
        static let lg: CGFloat = 24
        static let xl: CGFloat = 30
        static let full: CGFloat = 100
    }
}

// MARK: - Liquid glass card

struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = BNTheme.Radius.lg

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.25))
                }
                .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
                .shadow(color: .black.opacity(0.03), radius: 3, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.6), lineWidth: 0.5)
            )
    }
}

// MARK: - Liquid glass inset (for pills, badges)

struct LiquidGlassInset: ViewModifier {
    var cornerRadius: CGFloat = BNTheme.Radius.sm

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.2))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 0.5)
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = BNTheme.Radius.lg) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius))
    }

    func glassInset(cornerRadius: CGFloat = BNTheme.Radius.sm) -> some View {
        modifier(LiquidGlassInset(cornerRadius: cornerRadius))
    }
}
