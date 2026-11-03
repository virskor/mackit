import SwiftUI

/// A block-style segmented control. Two width modes: the options split the
/// available width evenly so the control fills its container edge to edge
/// (`.equal`), or each option hugs its own label and the control hugs its
/// content the way a native segmented control sizes itself (`.content`).
///
/// Built from buttons rather than the native `.segmented` picker because that
/// control sizes itself from its labels — `.frame(maxWidth: .infinity)` grows
/// it only part of the way — and a filter band that stops short of both edges
/// reads as a layout mistake. The same bridging is what rules the picker out
/// for a centered toolbar: on current macOS it ignores `.fixedSize()` and
/// fills whatever width it is offered, stretching localized labels into equal
/// segments that cramp the longest one, so `.content` width is built here.
/// The treatment follows the native control: the selection wears the accent
/// fill, hairlines separate the segments, and the track is the same
/// translucent fill the page's search field uses.
struct SegmentedBlock<Item: Hashable>: View {
    /// The options, in display order. They must be distinct — each one is
    /// the selection's identity.
    let items: [Item]
    /// An option's label. Localization is the caller's business.
    var title: (Item) -> String
    /// How the segments share the control's width. Defaults to `.equal`.
    var width: SegmentWidth = .equal
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                Button {
                    selection = item
                } label: {
                    Text(verbatim: title(item))
                        .font(Theme.Typography.subheadline.weight(selection == item ? .semibold : .regular))
                        .foregroundStyle(selection == item ? Theme.Palette.onColor : Color.primary)
                        .lineLimit(1)
                        .modifier(SegmentSizing(fills: width == .equal))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(selection == item ? Theme.Palette.info : Color.clear)
                // The hairline rides the segment's leading edge rather than
                // sitting beside it as a view of its own — see the note on
                // the stack's fixed height below.
                .overlay(alignment: .leading) {
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.Palette.hairline)
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
        // `.content` width also refuses the offered width, so the control
        // hugs its labels instead of stretching with the card.
        .fixedSize(horizontal: width == .content, vertical: false)
        .background(Theme.Palette.surfaceHover)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .animation(.easeOut(duration: Theme.Motion.stateChange), value: selection)
    }

    /// How the segments share the control's width.
    enum SegmentWidth: Hashable, Sendable {
        /// The segments split the available width evenly and the control
        /// fills its container edge to edge: a filter band spanning a card.
        case equal
        /// Each segment hugs its own label — the padding is for the pointer,
        /// not for the layout — and the control hugs its content. When the
        /// container runs out of room the labels truncate at the tail rather
        /// than the segments stretching.
        case content
    }
}

/// One segment's share of the control's width: its even slice of the offered
/// width in `.equal` mode, or its label's own width plus a comfortable
/// horizontal margin in `.content` mode.
private struct SegmentSizing: ViewModifier {
    var fills: Bool

    func body(content: Content) -> some View {
        if fills {
            content.frame(maxWidth: .infinity)
        } else {
            content.padding(.horizontal, 10)
        }
    }
}
