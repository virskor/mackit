import SwiftUI

/// The divider between the category rail and the item table, draggable to
/// resize the rail.
///
/// The rail's width is a preference rather than a fixed constant: a long path
/// in the table wants the rail narrow, a long category title wants it wide,
/// and the localizations disagree about which is wider. Dragging moves the
/// boundary the way an AppKit split view does.
struct ColumnResizeDivider: View {
    /// The rail's current width; dragging writes it back.
    @Binding var width: CGFloat
    /// The widths the rail may take. The floor keeps every category title
    /// readable; the ceiling leaves the table its name column.
    var bounds: ClosedRange<CGFloat>
    /// Whether the boundary may be dragged right now. A scan holds the layout
    /// still — no scrolling either — so the row being read does not move
    /// under the pointer.
    var isDraggable: Bool = true

    /// The drag's translation at the previous event, so the width follows the
    /// pointer's delta instead of jumping to its absolute position.
    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        // Not draggable means not grabbable either: a resize cursor over a
        // divider that refuses to move reads as a broken control.
        if isDraggable {
            line
                .gesture(dragGesture)
                .onHover { hovering in
                    // The resize cursor is pushed and popped with the hover,
                    // the same pairing the rest of AppKit relies on, so
                    // leaving the divider restores whatever cursor was there.
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        } else {
            line
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.Palette.separator)
            .frame(width: 1)
            // The line is 1pt wide; the grab area is not. A 1pt hit target is
            // a pixel-hunt, so the frame widens around the line — the extra
            // width is transparent and only the line shows.
            .frame(width: 9)
            .contentShape(Rectangle())
    }

    private var dragGesture: some Gesture {
        // minimumDistance 0 on purpose: a divider has no tap action to
        // protect, and a drag shorter than the system's tap threshold should
        // still nudge the boundary.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.translation.width - lastTranslation
                lastTranslation = value.translation.width
                // Clamped by hand rather than ClosedRange.clamped(to:): that
                // one is package-protected in the standard library.
                let proposed = width + dx
                width = min(max(proposed, bounds.lowerBound), bounds.upperBound)
            }
            .onEnded { _ in
                lastTranslation = 0
            }
    }
}
