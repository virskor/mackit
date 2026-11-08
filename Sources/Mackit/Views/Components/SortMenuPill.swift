import SwiftUI

/// A menu pill labelled with the current sort order, one item per option.
///
/// Shared by the list-style tool pages so every sort control reads as one
/// family: the pill shape and chevron come from `MenuPill`, the direction
/// glyph says what the menu does. The caller owns the state, so a sort that
/// must not outlive its page can stay in the page's model.
struct SortMenuPill<Option: Identifiable>: View {
    let options: [Option]
    let selection: Option
    let optionTitle: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        MenuPill {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(Theme.Typography.footnoteMedium)

                Text(verbatim: optionTitle(selection))
            }
        } content: {
            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    Text(verbatim: optionTitle(option))
                }
            }
        }
    }
}
