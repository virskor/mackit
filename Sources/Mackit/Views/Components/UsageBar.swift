import SwiftUI

/// Capsule-shaped proportion bar, used for 0…1 ratio displays such as disk usage.
struct UsageBar: View {
    /// Fraction; clamped to 0…1.
    var fraction: Double
    var tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}
