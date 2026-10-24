import SwiftUI

/// One of the sidebar footer's capsules: a pill in the footer's accent tint,
/// carrying the footer's 11pt semibold secondary type.
///
/// The brand chip and the share capsule sit side by side at the foot of the
/// sidebar; one definition of the pill is what makes them read as a pair —
/// same shape, same fill, same type — with only the content telling them
/// apart. While each carried its own copy of the metrics, a change to one
/// silently left the other behind.
///
/// The fill is the accent tint the badges use (see IconBadge) rather than the
/// sidebar's selection gray, so a capsule reads as branding rather than as a
/// row the pointer happens to be over.
struct FooterCapsule<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
}
