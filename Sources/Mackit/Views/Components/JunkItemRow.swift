import SwiftUI

/// Cleanup item list row: category icon + name/path + size + risk badge.
struct JunkItemRow: View {
    let item: JunkItem
    /// Subtitle; shows the source description when nil.
    var subtitle: String?
    /// Real icon of the app itself; shows the category symbol icon when nil.
    var icon: NSImage?
    /// Which end of the subtitle gives way when it does not fit. Paths lose
    /// their head (the tail names the entry); a plain name loses its tail.
    var subtitleTruncation: Text.TruncationMode = .head

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                CategoryIcon(category: item.category)
            }

            ItemTitleBlock(
                title: item.title,
                subtitle: subtitle ?? item.detail,
                truncation: subtitleTruncation
            )

            Spacer(minLength: 8)

            Text(verbatim: item.sizeText)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()

            RiskBadge(risk: item.risk)
        }
        .padding(.vertical, 2)
    }
}
