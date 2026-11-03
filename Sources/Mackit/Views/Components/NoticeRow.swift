import SwiftUI

/// Notice row: leading icon + optional title + explanatory text + optional trailing action.
///
/// Used for risk warnings and cleanup-method notes in the confirmation panel.
struct NoticeRow: View {
    let systemImage: String
    var tint: Color = .secondary
    var title: String?
    let message: String
    /// Trailing action button; degrades to a plain notice row when nil. The title likewise passes a localized result.
    var action: (title: String, handler: () -> Void)?
    /// Tooltip for the action button, naming where it leads. Optional: most actions say everything in their label ("Select all").
    var actionHelp: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    // What the caller passes in is already a localized result; verbatim avoids looking it up again as a key
                    Text(verbatim: title)
                        .font(Theme.Typography.subheadlineEmphasis)
                }
                // No `.fixedSize(vertical:)` here: same hazard as AlertCard —
                // it makes the hosting page size its content region to the
                // laid-out rows instead of the card, and the oversized page
                // is then centered and clipped by macOS 26+.
                Text(verbatim: message)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let action {
                Button(action: action.handler) {
                    Text(verbatim: action.title)
                        .font(Theme.Typography.footnote)
                }
                .controlSize(.small)
                .fixedSize()
                .optionalHelp(actionHelp)
            }
        }
    }
}
