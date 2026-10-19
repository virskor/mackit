import SwiftUI

/// Two-line text block of main title + secondary note, used for table cells and list rows.
struct ItemTitleBlock: View {
    let title: String
    let subtitle: String
    var titleSize: CGFloat = 12
    var subtitleSize: CGFloat = 10
    /// Truncation direction of the subtitle: paths truncate at the head in tables, notes truncate at the tail.
    var truncation: Text.TruncationMode = .tail

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // title / subtitle both come from the caller, already localized or formatted results
            Text(verbatim: title)
                .font(.system(size: titleSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(verbatim: subtitle)
                .font(.system(size: subtitleSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(truncation)
        }
    }
}
