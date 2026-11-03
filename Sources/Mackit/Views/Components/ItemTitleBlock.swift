import SwiftUI

/// Text block of main title + secondary note + optional path line, used for
/// table cells and list rows.
struct ItemTitleBlock: View {
    let title: String
    let subtitle: String
    /// Third line, for callers that carry a path without a column of its own
    /// (the item table's name column). Truncates at the head so the tail still
    /// names the entry, the same treatment the old path column had.
    var tertiary: String?
    /// Full text of the third line for the hover tooltip; nil shows the
    /// abbreviated line itself, which is a no-op tooltip.
    var tertiaryHelp: String?
    var titleSize: CGFloat = 12
    var subtitleSize: CGFloat = 10
    var tertiarySize: CGFloat = 10
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

            // Command-line entries have no path; an empty line would still
            // claim a row of height.
            if let tertiary, !tertiary.isEmpty {
                Text(verbatim: tertiary)
                    .font(.system(size: tertiarySize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(tertiaryHelp ?? tertiary)
            }
        }
    }
}
