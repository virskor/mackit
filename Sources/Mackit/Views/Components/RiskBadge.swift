import SwiftUI

/// Risk level badge.
struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Label(risk.title, systemImage: risk.symbol)
            .font(Theme.Typography.captionMedium)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(Theme.Palette.Tint.badge), in: Capsule())
            .foregroundStyle(tint)
            .help(risk.hint)
    }

    private var tint: Color {
        switch risk {
        case .safe: return Theme.Palette.success
        case .review: return Theme.Palette.warning
        case .caution: return Theme.Palette.danger
        }
    }
}
