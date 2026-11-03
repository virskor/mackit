import SwiftUI

/// The cleanable-items page's category rail.
///
/// The developer categories used to be a section of the window's sidebar.
/// They filter the item table, so they belong beside it: the sidebar keeps
/// the window's destinations (all items, the general module, the tools),
/// and this column keeps the filters the table responds to — one click
/// switches the filter without leaving the page.
///
/// A column beside the table, the way the disk analysis page puts its
/// directory list beside the treemap: the rail keeps whatever width the page
/// gives it (and the divider beside it makes that width draggable), the table
/// takes the rest, and each scrolls inside the full height.
struct CategoryRailView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        // No header of its own: the rail sits beside the table's own column
        // headers, and a "分类" label above the rows read as a second title
        // bar competing with them. The first row starts at the top of the
        // column, beside the table's first entry.
        List {
            ForEach(vm.developerCategories) { category in
                NavRowView(
                    icon: category.iconSource,
                    tint: category.tint,
                    title: category.title,
                    // The rail only exists on the item list, so the
                    // sidebar's "is any module page active" guard does
                    // not apply here: the selection is the filter.
                    isSelected: vm.selectedCategory == category,
                    figures: (
                        count: vm.categoryCounts[category] ?? 0,
                        size: vm.categoryTotals[category] ?? 0
                    ),
                    action: { vm.selectCategory(category) }
                )
                .help(category.summary)
                .listRowSeparator(.hidden)
            }
        }
        // The sidebar's list style on purpose: the rows keep the same insets
        // and the same pill-to-content alignment they had in the window's
        // sidebar. Its own backdrop is hidden because the rail sits inside
        // the detail card, which paints its own — a second backdrop behind
        // the rows would match neither.
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // The list fills the column's height so the rail scrolls on its own
        // instead of stretching the page. The width is the page's to set:
        // this view fills whatever it is given.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
