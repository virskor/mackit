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
                .font(.system(size: 12))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    // What the caller passes in is already a localized result; verbatim avoids looking it up again as a key
                    Text(verbatim: title)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(verbatim: message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

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
    }
}
