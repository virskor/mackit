import SwiftUI

/// The app's prompt composition: a badge, a line of copy and one call to
/// action, vertically centered.
///
/// Every screen that has nothing to show yet is this composition, at one of
/// two scales: the full-screen front door (the welcome page, the general
/// module's empty state, the disk analysis page before its first
/// measurement) and the compact in-column placeholder (an unscanned folder,
/// an unreadable one, a protected one). Spelling it out per screen is how the
/// six variants this replaces drifted apart — the same pattern in six sets of
/// metrics — so the composition lives here once and callers only choose their
/// subject.
///
/// The defaults are the brand hero: the app icon on an accent-tinted
/// squircle, rising in sequence. A prompt about something other than the app
/// itself passes its own symbol with `brandIcon: false`; a compact one drops
/// to a bare tertiary symbol at 28pt with `rises: false`, since it appears
/// and disappears as the user navigates.
///
/// `title` is optional — a prompt that only explains (the disk analysis
/// page's) omits it rather than passing an empty string, which would still
/// occupy a line and break the stagger. `hint` is the quieter second line for
/// the one caveat a prompt needs to carry (the Full Disk Access one).
/// `Accessory` sits beside the action (the settings link) and `Footer` under
/// the button (the welcome page's project-roots hint); both default to
/// nothing, so screens without either don't pass an empty view.
///
/// No `.fixedSize` on the copy: combined with the entrance animation it makes
/// SwiftUI's layout oscillate every frame, and the layout-loop recovery
/// collapses the sidebar and toolbar along with it.
struct HeroPromptView<Accessory: View, Footer: View>: View {
    // MARK: Badge

    /// SF Symbol drawn in the badge; ignored while `brandIcon` is set.
    var systemImage: String = "sparkle.magnifyingglass"
    /// Draw the full-color brand icon instead of `systemImage`. Off for
    /// prompts whose subject is not the app itself.
    var brandIcon = true
    var tint: Color = .accentColor
    var diameter: CGFloat = 84
    var symbolSize: CGFloat = 60
    var symbolWeight: Font.Weight = .regular
    /// Corner radius of the badge's squircle; nil for a full circle.
    var cornerRadius: CGFloat? = 18
    /// Opacity of the tinted fill behind the symbol. 0 leaves a bare symbol,
    /// which is what the compact in-column prompts use.
    var fillOpacity: Double = 0.12

    // MARK: Copy

    /// Headline; omit for a prompt that is only an explanation.
    var title: String?
    var message: String
    /// Caps the message's width so a long explanation stays a paragraph
    /// instead of one window-wide line; nil uses the full width.
    var messageMaxWidth: CGFloat?
    /// Quieter second line under the message, for the caveat a prompt needs
    /// to carry (the Full Disk Access one).
    var hint: String?
    var hintMaxWidth: CGFloat?

    // MARK: Action

    /// The action's label; omit for a prompt that only informs.
    var actionTitle: String?
    var actionImage: String?
    var actionStyle: BrandCTAButton.Style = .primary
    /// Shrinks the button for use inside a narrow column.
    var actionCompact = false
    var action: (() -> Void)?

    /// Content beside the action — the settings link the protected-folder
    /// prompt adds.
    @ViewBuilder var actionAccessory: Accessory

    // MARK: Entrance

    /// Whether the prompt assembles itself top-down on appear. On for the
    /// full-screen front doors; off for the in-column placeholders, where a
    /// replaying entrance on every navigation reads as lag rather than
    /// polish.
    var rises = true

    /// Extra content under the button — the welcome page's project-roots
    /// hint. Rises with the rest of the screen, so pass it without its own
    /// motion.
    @ViewBuilder var footer: Footer

    init(
        systemImage: String = "sparkle.magnifyingglass",
        brandIcon: Bool = true,
        tint: Color = .accentColor,
        diameter: CGFloat = 84,
        symbolSize: CGFloat = 60,
        symbolWeight: Font.Weight = .regular,
        cornerRadius: CGFloat? = 18,
        fillOpacity: Double = 0.12,
        title: String? = nil,
        message: String,
        messageMaxWidth: CGFloat? = nil,
        hint: String? = nil,
        hintMaxWidth: CGFloat? = nil,
        actionTitle: String? = nil,
        actionImage: String? = nil,
        actionStyle: BrandCTAButton.Style = .primary,
        actionCompact: Bool = false,
        rises: Bool = true,
        action: (() -> Void)? = nil,
        @ViewBuilder actionAccessory: () -> Accessory = { EmptyView() },
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.brandIcon = brandIcon
        self.tint = tint
        self.diameter = diameter
        self.symbolSize = symbolSize
        self.symbolWeight = symbolWeight
        self.cornerRadius = cornerRadius
        self.fillOpacity = fillOpacity
        self.title = title
        self.message = message
        self.messageMaxWidth = messageMaxWidth
        self.hint = hint
        self.hintMaxWidth = hintMaxWidth
        self.actionTitle = actionTitle
        self.actionImage = actionImage
        self.actionStyle = actionStyle
        self.actionCompact = actionCompact
        self.rises = rises
        self.action = action
        self.actionAccessory = actionAccessory()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            entrance(
                IconBadge(
                    systemImage: systemImage,
                    // The brand image is full-color, so an SF Symbol can only
                    // replace it, never tint it; prompts about something other
                    // than the app itself opt out.
                    image: brandIcon ? BrandIcon.image : nil,
                    tint: tint,
                    diameter: diameter,
                    symbolSize: symbolSize,
                    symbolWeight: symbolWeight,
                    cornerRadius: cornerRadius,
                    fillOpacity: fillOpacity
                )
                .accessibilityHidden(true),
                delay: 0
            )

            entrance(
                VStack(spacing: 8) {
                    if let title {
                        Text(verbatim: title)
                            .font(.system(size: 24, weight: .bold))
                    }

                    Text(verbatim: message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: messageMaxWidth)

                    if let hint {
                        Text(verbatim: hint)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: hintMaxWidth)
                    }
                }
                .padding(.top, 18),
                // Without a headline the message takes its slot in the
                // stagger, so the prompt still assembles top-down.
                delay: title == nil ? 0.08 : 0.16
            )

            if let actionTitle, let action {
                entrance(
                    HStack(spacing: 10) {
                        // The prompt's action is the primary action of the
                        // screen it sits on, so it carries the brand CTA's
                        // full treatment.
                        BrandCTAButton(
                            title: actionTitle,
                            systemImage: actionImage,
                            style: actionStyle,
                            compact: actionCompact,
                            action: action
                        )

                        actionAccessory
                    }
                    .padding(.top, 26),
                    delay: title == nil ? 0.16 : 0.24
                )
            }

            entrance(footer, delay: 0.32)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Applies the staggered entrance when `rises` is set.
    @ViewBuilder
    private func entrance<Content: View>(_ content: Content, delay: Double) -> some View {
        if rises {
            content.rise(delay: delay)
        } else {
            content
        }
    }
}
