import SwiftUI

/// The tray panel's tab header.
///
/// The selected tab is not a plate floating inside a track: it is a cut-out
/// in a tinted header band, and the surface that shows through the cut-out is
/// the same surface the page below uses. The selected tab therefore merges
/// with the page like a folder tab — rounded top corners, concave fillets at
/// its base, and no seam between tab and content.
///
/// The band spans the panel edge to edge. Its own top corners are square and
/// the panel window's rounded corner clips them: giving the band its own
/// rounding left a visible inset between the band and the window on the two
/// top corners. Only the page's top corners, which sit inside the panel and
/// mark where the band ends, carry a radius.
///
/// The band is tinted rather than filled with an elevated color so the panel
/// material itself is the page surface. That keeps the header working in dark
/// appearance without a second surface token: the tab is simply where the
/// band is absent.
struct PanelTabHeader: View {
    @Binding var selection: PanelTab

    /// The band's height. The page starts at the band's bottom edge, and the
    /// band bleeds a little past it to round the page's top corners.
    private let headerHeight: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PanelTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(verbatim: tab.title)
                        .font(selection == tab ? Theme.Typography.calloutEmphasis : Theme.Typography.callout)
                        .foregroundStyle(selection == tab ? Theme.Palette.info : Color.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .frame(height: headerHeight)
        // The background is taller than the header on purpose: its last few
        // points sit behind the page's first rows and round the page's top
        // corners. A background does not affect layout, so the page still
        // starts exactly at the band's bottom edge.
        .background(alignment: .top) {
            PanelTabBandShape(
                selectedIndex: selectedIndex,
                headerHeight: headerHeight,
                tabCornerRadius: Theme.Radius.lg,
                filletRadius: Theme.Radius.sm,
                contentCornerRadius: Theme.Radius.lg
            )
            .fill(Theme.Palette.info.opacity(Theme.Palette.Tint.card))
            .frame(height: headerHeight + Theme.Radius.lg)
        }
    }

    private var selectedIndex: Int {
        PanelTab.allCases.firstIndex(of: selection) ?? 0
    }
}

/// The tinted header band with the selected tab cut out of it.
///
/// The band is drawn as the regions left and right of the selected tab. A tab
/// at either end reaches the panel edge, so that side has no band region at
/// all — the page surface runs flush to the window edge and the window's own
/// corner rounds it.
///
/// Corners are cubic curves rather than `Path.addArc`: in the flipped view
/// space the arc's clockwise flag is easy to invert, while explicit control
/// points state the tangent direction at both ends.
private struct PanelTabBandShape: Shape {
    let selectedIndex: Int
    let headerHeight: CGFloat
    let tabCornerRadius: CGFloat
    let filletRadius: CGFloat
    let contentCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tabCount = PanelTab.allCases.count
        guard tabCount > 0, rect.width > 0, rect.height > 0 else { return path }

        let cellWidth = rect.width / CGFloat(tabCount)
        let index = min(max(selectedIndex, 0), tabCount - 1)
        let tabLeft = CGFloat(index) * cellWidth
        let tabRight = tabLeft + cellWidth
        let height = headerHeight

        // The standard circle-to-Bézier constant for a 90° arc.
        let k: CGFloat = 0.552_284_749_8

        // The panel width is fixed, but clamping keeps a narrower host from
        // producing an inverted path: the tab's two top corners must fit its
        // cell, and each base fillet must fit between the tab side and the
        // page's rounded corner.
        let tabRadius = min(tabCornerRadius, cellWidth / 2, height / 2)
        let contentRadius = min(contentCornerRadius, rect.width / 2, height / 2)
        let leftFillet = min(filletRadius, max(0, tabLeft - contentRadius))
        let rightFillet = min(filletRadius, max(0, rect.width - tabRight - contentRadius))

        // Left of the selected tab. At the leftmost tab there is no band here:
        // the tab itself is the left edge of the panel.
        if index > 0 {
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: tabLeft + tabRadius, y: 0))
            path.addCurve(
                to: CGPoint(x: tabLeft, y: tabRadius),
                control1: CGPoint(x: tabLeft + tabRadius - k * tabRadius, y: 0),
                control2: CGPoint(x: tabLeft, y: tabRadius - k * tabRadius)
            )
            path.addLine(to: CGPoint(x: tabLeft, y: height - leftFillet))
            path.addCurve(
                to: CGPoint(x: tabLeft - leftFillet, y: height),
                control1: CGPoint(x: tabLeft, y: height - leftFillet + k * leftFillet),
                control2: CGPoint(x: tabLeft - leftFillet + k * leftFillet, y: height)
            )
            path.addLine(to: CGPoint(x: contentRadius, y: height))
            path.addCurve(
                to: CGPoint(x: 0, y: height + contentRadius),
                control1: CGPoint(x: contentRadius - k * contentRadius, y: height),
                control2: CGPoint(x: 0, y: height + contentRadius - k * contentRadius)
            )
            path.closeSubpath()
        }

        // Right of the selected tab. At the rightmost tab there is no band
        // here, for the same reason.
        if index < tabCount - 1 {
            path.move(to: CGPoint(x: rect.width, y: 0))
            path.addLine(to: CGPoint(x: tabRight - tabRadius, y: 0))
            path.addCurve(
                to: CGPoint(x: tabRight, y: tabRadius),
                control1: CGPoint(x: tabRight - tabRadius + k * tabRadius, y: 0),
                control2: CGPoint(x: tabRight, y: tabRadius - k * tabRadius)
            )
            path.addLine(to: CGPoint(x: tabRight, y: height - rightFillet))
            path.addCurve(
                to: CGPoint(x: tabRight + rightFillet, y: height),
                control1: CGPoint(x: tabRight, y: height - rightFillet + k * rightFillet),
                control2: CGPoint(x: tabRight + rightFillet - k * rightFillet, y: height)
            )
            path.addLine(to: CGPoint(x: rect.width - contentRadius, y: height))
            path.addCurve(
                to: CGPoint(x: rect.width, y: height + contentRadius),
                control1: CGPoint(x: rect.width - contentRadius + k * contentRadius, y: height),
                control2: CGPoint(x: rect.width, y: height + contentRadius - k * contentRadius)
            )
            path.closeSubpath()
        }

        return path
    }
}
