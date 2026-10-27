import SwiftUI

/// A toolbar menu button in the app's translucent pill: a borderless menu
/// with a leading label and a trailing chevron, on the same track the
/// segmented controls use.
///
/// Both of the large-file page's toolbar menus — the sort order and the size
/// threshold — share it, so the two read as one control family rather than as
/// two one-off buttons. The label is the caller's business (an icon plus the
/// current value, or just the value); the chevron, the pill and the
/// borderless behavior live here once.
struct MenuPill<Label: View, Content: View>: View {
    private let label: Label
    private let content: Content

    init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label()
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 5) {
                label

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        // The label carries its own chevron; the platform's indicator would
        // draw a second one beside it.
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
