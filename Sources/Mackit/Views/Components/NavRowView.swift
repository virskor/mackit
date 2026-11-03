import SwiftUI

/// One navigation row: icon, title, and the trailing slot that carries the
/// figures or the tool's spinner.
///
/// Shared by the window's sidebar (the destinations and the tools) and the
/// item page's category rail (the filters the table responds to), so a row
/// reads the same whichever column it sits in.
///
/// Every row is one line at one height. The cleanup rows used to stack the
/// item count under the title while the module entries were single-line,
/// so the list read as two different controls piled on each other — the
/// count now sits beside the size in the trailing slot instead. That slot
/// exists on every row whether it is filled or not, so the titles share
/// one ragged edge and the rows share one height, which is what makes the
/// sidebar read as a list rather than as a draft.
///
/// The selection follows what the system's own sidebars do now: a light
/// rounded pill inset from the row's edges, with the row's colors left
/// alone. An accent-filled row with inverted contents — the treatment the
/// system used to use — reads as a pressed button sitting among rows that
/// aren't, and a flat tint of the row's own background read as hover.
///
/// Rows are Buttons with `listRowBackground` rather than `List(selection:)`:
/// tag selection of an optional value doesn't respond to clicks in a
/// sidebar List (rows don't react when clicked), and binding the selection
/// to the checkbox state would let the table's selection write-back clear
/// the user's picks. Button + background is the known-working pattern.
struct NavRowView: View {
    let icon: CategoryIcon.Source
    let tint: Color
    let title: String
    let isSelected: Bool
    /// Item count and total, for the cleanup rows. The module entries
    /// leave it nil — they report their own totals on their pages.
    var figures: (count: Int, size: Int64)? = nil
    /// A measurement is running in the background (the disk analysis
    /// tool) or a Homebrew query is in flight. Only the running flag is
    /// read, deliberately not the scanned-directory count, which changes
    /// several times a second and would re-render the whole sidebar for
    /// a number the row does not show.
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                CategoryIcon(icon, tint: tint, size: 15, width: 22)

                Text(verbatim: title)
                    .font(Theme.Typography.bodyMedium)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let figures {
                    // Fixed rather than flexible: when the column narrows,
                    // the title is what should give way, never the figures.
                    HStack(spacing: 6) {
                        Text(verbatim: L10n.items(figures.count))
                        Text(verbatim: Formatters.bytes(figures.size))
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }

                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                // `Color.primary` rather than a hand-mixed white or a fixed
                // gray: it is black in light mode and white in dark mode, so
                // one opacity darkens the pill against the light sidebar and
                // lightens it against the dark one, with the row's own text
                // keeping its contrast either way. A step above the hover
                // fills the rest of the app uses (0.06), so a selected row
                // still reads as more than the one the pointer is over.
                .fill(isSelected ? Theme.Palette.surfaceHover : .clear)
                // Inset from the row's edges the way the system's selection
                // is, so the highlight reads as belonging to the row rather
                // than as a band across the sidebar.
                .padding(.horizontal, 8)
        )
    }
}
