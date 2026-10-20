import SwiftUI

/// The full-screen call to action shown before the first scan: app logo,
/// copy and one button, rising in sequence.
///
/// Shared by the welcome page and the general module's empty state — the same
/// front door whichever module the user opens, which is why the composition
/// lives here once instead of being spelled out per screen. `Footer` carries
/// the welcome page's project-roots hint and defaults to nothing, so screens
/// without one don't have to pass an empty view.
///
/// No `.fixedSize` on the copy: combined with the entrance animation it makes
/// SwiftUI's layout oscillate every frame, and the layout-loop recovery
/// collapses the sidebar and toolbar along with it.
struct HeroPromptView<Footer: View>: View {
    let title: String
    let message: String
    let actionTitle: String
    var actionImage: String?
    let action: () -> Void

    /// Extra content under the button — the welcome page's project-roots hint.
    /// Rises with the rest of the screen, so pass it without its own motion.
    @ViewBuilder var footer: Footer

    init(
        title: String,
        message: String,
        actionTitle: String,
        actionImage: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.actionImage = actionImage
        self.action = action
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            IconBadge(
                systemImage: "sparkle.magnifyingglass",
                image: BrandIcon.image,
                tint: .accentColor,
                diameter: 84,
                symbolSize: 60,
                symbolWeight: .regular,
                cornerRadius: 18,
                fillOpacity: 0.12
            )
            .accessibilityHidden(true)
            .rise(delay: 0)

            VStack(spacing: 8) {
                Text(verbatim: title)
                    .font(.system(size: 24, weight: .bold))
                    .rise(delay: 0.08)

                Text(verbatim: message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .rise(delay: 0.16)
            }
            .padding(.top, 18)

            // This hero's CTA always starts a scan (welcome page and the
            // general module's empty state), so it carries the Liquid Glass
            // pilot; other BrandCTAButton users opt in separately.
            BrandCTAButton(
                title: actionTitle,
                systemImage: actionImage,
                glass: true,
                action: action
            )
            .rise(delay: 0.24)
            .padding(.top, 26)

            footer
                .rise(delay: 0.32)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
