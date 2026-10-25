import SwiftUI

/// A block-style segmented control: the options split the available width
/// evenly, so the control fills its container edge to edge.
///
/// Built from buttons rather than the native `.segmented` picker because that
/// control sizes itself from its labels — `.frame(maxWidth: .infinity)` grows
/// it only part of the way — and a filter band that stops short of both edges
/// reads as a layout mistake. The treatment follows the native control: the
/// selection wears the accent fill, hairlines separate the segments, and the
/// track is the same translucent fill the page's search field uses.
struct SegmentedBlock<Item: Hashable>: View {
    /// The options, in display order. They must be distinct — each one is the
    /// selection's identity.
    let items: [Item]
    /// An option's label. Localization is the caller's business.
    var title: (Item) -> String
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                Button {
                    selection = item
                } label: {
                    Text(verbatim: title(item))
                        .font(.system(size: 12, weight: selection == item ? .semibold : .regular))
                        .foregroundStyle(selection == item ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(selection == item ? Color.accentColor : Color.clear)
                // The hairline rides the segment's leading edge rather than
                // sitting beside it as a view of its own — see the note on the
                // stack's fixed height below.
                .overlay(alignment: .leading) {
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 0.5)
                    }
                }
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        // The control's height comes from its content and nothing else. It
        // lives in columns whose loading state is a flexible sibling, so the
        // column proposes the whole card's height: a flexible child here (the
        // hairline dividers used to be bare Rectangles beside the segments)
        // swallows that height and the band renders as a tall empty block with
        // its labels at the bottom. The dividers now ride the segments' edges
        // as overlays, and the stack refuses the offered height outright.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: selection)
    }
}
