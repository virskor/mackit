import SwiftUI

/// Risk level badge.
struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Label(risk.title, systemImage: risk.symbol)
            .font(.system(size: 10, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
            .help(risk.hint)
    }

    private var tint: Color {
        switch risk {
        case .safe: return .green
        case .review: return .orange
        case .caution: return .red
        }
    }
}
