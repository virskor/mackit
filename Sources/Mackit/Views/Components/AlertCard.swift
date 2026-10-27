import SwiftUI

/// A bordered callout card for user attention — the app's take on shadcn's
/// Alert (https://ui.shadcn.com/docs/components/base/alert).
///
/// shadcn's anatomy is `Alert / Icon / AlertTitle / AlertDescription /
/// AlertAction`: a rounded, bordered card, a 16px icon column beside the
/// copy, a medium-weight single-line title over a muted description, and an
/// action pinned to the top-right. SwiftUI has no slot composition for that
/// here, so the parts are parameters of one struct, the way `NoticeRow` is
/// built.
///
/// The variant color rides on `tint`. shadcn carries it on the icon alone
/// (`text-current`) and tints the background only through documented class
/// overrides (`bg-amber-50`); this card tints icon, fill and border together
/// — the treatment `CleanResultCard`'s failure block already uses, so the
/// two alerts in the app share one material.
///
/// This is the page-level alert: a card the content area drops in above its
/// list. For the borderless warning rows inside the confirmation sheet,
/// `NoticeRow` stays the component — a card per warning would bury the
/// sheet's own list.
///
/// No `.fixedSize(vertical:)` on the copy: it makes the page that hosts this
/// card size its content region to the laid-out rows instead of the card, the
/// page then grows past the card, and macOS 26+ centers whatever the detail
/// column is handed that does not exactly fill it — clipping the page's
/// header above the window's top edge and its list below the bottom (the
/// app-uninstall page shipped that way once). The description wraps naturally
/// without it. Same hazard class as `HeroPromptView`'s no-fixedSize rule.
struct AlertCard: View {
    /// Leading symbol; nil leaves the card text-only.
    var systemImage: String?
    /// The accent carried by the icon, the fill and the border.
    var tint: Color = .accentColor
    var title: String?
    /// The body copy, localized by the caller like every other component's text.
    let message: String
    /// Trailing action button; degrades to a card with no button when nil.
    var action: (title: String, handler: () -> Void)?
    /// Tooltip for the action button, naming where it leads. Optional: most
    /// actions say everything in their label.
    var actionHelp: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                    // shadcn nudges its 16px icon down half a spacing unit so
                    // it sits on the title's first line; the card's content
                    // starts at the top, so the glyph needs the same nudge.
                    .offset(y: 1)
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                Text(verbatim: message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if let action {
                Button(action: action.handler) {
                    Text(verbatim: action.title)
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .fixedSize()
                .optionalHelp(actionHelp)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }
}
