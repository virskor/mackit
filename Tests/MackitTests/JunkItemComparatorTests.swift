import Foundation
import Testing

@testable import Mackit

/// Verifies the semantics and direction of the sort comparator.
///
/// This type is the single source of truth for sorting: header clicks, the
/// toolbar menu, and visibleItems all share it, so any semantic drift in any
/// of them shows up immediately as "arrow direction inconsistent with row order".
@MainActor
struct JunkItemComparatorTests {
    private func makeItem(
        title: String = "DerivedData",
        size: Int64 = 0,
        modified: Date? = nil
    ) -> JunkItem {
        JunkItem(
            ruleID: "test.\(title)",
            title: title,
            detail: "test",
            path: "/tmp/mackit-\(title)",
            category: .xcode,
            risk: .safe,
            size: size,
            modified: modified
        )
    }

    /// Names use natural ordering: file2 must sort before file10.
    /// Lexicographic order would give file10 < file2, contrary to user intuition.
    @Test func nameUsesNaturalOrdering() {
        let comparator = JunkItemComparator(field: .name, order: .forward)
        let file2 = makeItem(title: "file2")
        let file10 = makeItem(title: "file10")

        #expect(comparator.compare(file2, file10) == .orderedAscending)
        #expect(comparator.sorts(file2, before: file10))
        #expect(!comparator.sorts(file10, before: file2))
    }

    /// Size compares numerically, not as text — otherwise "9 KB" would sort after "10 KB".
    @Test func sizeComparesNumerically() {
        let comparator = JunkItemComparator(field: .size, order: .forward)
        let small = makeItem(title: "small", size: 9)
        let large = makeItem(title: "large", size: 10)

        #expect(comparator.compare(small, large) == .orderedAscending)
        #expect(comparator.sorts(small, before: large))
        #expect(comparator.compare(small, small) == .orderedSame)
    }

    /// Items with no modification date count as earliest: first in ascending order, last in descending order.
    @Test func missingModifiedCountsAsEarliest() {
        let comparator = JunkItemComparator(field: .modified, order: .forward)
        let unknown = makeItem(title: "unknown", modified: nil)
        let known = makeItem(title: "known", modified: Date(timeIntervalSince1970: 1000))

        #expect(comparator.sorts(unknown, before: known))
        #expect(comparator.compare(unknown, unknown) == .orderedSame)

        let reversed = JunkItemComparator(field: .modified, order: .reverse)
        #expect(reversed.sorts(known, before: unknown))
    }

    /// When the order flips, the sorting must flip with it: header clicks only
    /// change direction, and if the row order does not flip you get "arrow up
    /// but data actually descending".
    @Test func orderFlipReversesSorting() {
        let ascending = JunkItemComparator(field: .size, order: .forward)
        let descending = JunkItemComparator(field: .size, order: .reverse)
        let small = makeItem(title: "small", size: 1)
        let large = makeItem(title: "large", size: 2)

        #expect(ascending.sorts(small, before: large))
        #expect(descending.sorts(large, before: small))
    }

    /// Comparators with the same field + order must be equal.
    /// SwiftUI relies on this to match the comparator written back by header
    /// clicks against the existing column (which column the arrow is drawn on),
    /// and the toolbar menu relies on it to decide which item is checked.
    @Test func equalFieldAndOrderAreEqual() {
        #expect(JunkItemComparator(field: .size, order: .forward)
            == JunkItemComparator(field: .size, order: .forward))
        #expect(JunkItemComparator(field: .size, order: .forward)
            != JunkItemComparator(field: .size, order: .reverse))
        #expect(JunkItemComparator(field: .size, order: .forward)
            != JunkItemComparator(field: .name, order: .forward))
    }

    /// Every preset must map to the correct "field × direction" combination —
    /// if the menu says "size small to large", it really must be ascending.
    @Test func presetsMapToExpectedComparators() {
        #expect(ItemSort.sizeDescending.comparator
            == JunkItemComparator(field: .size, order: .reverse))
        #expect(ItemSort.sizeAscending.comparator
            == JunkItemComparator(field: .size, order: .forward))
        #expect(ItemSort.nameAscending.comparator
            == JunkItemComparator(field: .name, order: .forward))
        #expect(ItemSort.nameDescending.comparator
            == JunkItemComparator(field: .name, order: .reverse))
        #expect(ItemSort.dateDescending.comparator
            == JunkItemComparator(field: .modified, order: .reverse))
        #expect(ItemSort.dateAscending.comparator
            == JunkItemComparator(field: .modified, order: .forward))
    }

    /// The toolbar's label names the sort in force, which needs the reverse
    /// lookup. Every preset must round-trip through its comparator, and every
    /// comparator a header click can produce (three fields × two directions)
    /// must resolve to a preset — a miss would leave the row naming a sort
    /// that isn't the one in force.
    @Test func everyComparatorResolvesToThePresetItCameFrom() {
        for preset in ItemSort.allCases {
            #expect(ItemSort(comparator: preset.comparator) == preset)
        }
        for field in [JunkItemComparator.Field.name, .size, .modified] {
            for order in [SortOrder.forward, .reverse] {
                #expect(
                    ItemSort(comparator: JunkItemComparator(field: field, order: order)) != nil,
                    "no preset covers \(field) / \(order)"
                )
            }
        }
    }

    /// visibleItems must follow sortComparator: this is the path where header
    /// clicks actually take effect (SwiftUI's Table only updates the binding
    /// and does not sort the data itself).
    @Test func visibleItemsFollowSortComparator() {
        let vm = AppViewModel(statsPolling: false)
        vm.autoSelectRisk = .none
        vm.apply(.discovered([
            makeItem(title: "b", size: 20),
            makeItem(title: "a", size: 30),
            makeItem(title: "c", size: 10)
        ]))

        // Default size descending
        #expect(vm.visibleItems.map(\.title) == ["a", "b", "c"])

        vm.sortComparator = ItemSort.sizeAscending.comparator
        #expect(vm.visibleItems.map(\.title) == ["c", "b", "a"])

        vm.sortComparator = ItemSort.nameAscending.comparator
        #expect(vm.visibleItems.map(\.title) == ["a", "b", "c"])

        vm.sortComparator = ItemSort.nameDescending.comparator
        #expect(vm.visibleItems.map(\.title) == ["c", "b", "a"])

        // Flipping direction directly (simulating a header click) works too
        vm.sortComparator = JunkItemComparator(field: .name, order: .forward)
        #expect(vm.visibleItems.map(\.title) == ["a", "b", "c"])
    }

    /// Filtering and sorting do not interfere: changing the sort must not wipe out active search/category filters.
    @Test func sortingPreservesActiveFilters() {
        let vm = AppViewModel(statsPolling: false)
        vm.autoSelectRisk = .none
        vm.apply(.discovered([
            makeItem(title: "xcode big", size: 20),
            makeItem(title: "go small", size: 10)
        ]))

        vm.searchText = "go"
        vm.sortComparator = ItemSort.sizeAscending.comparator
        #expect(vm.visibleItems.map(\.title) == ["go small"])

        vm.searchText = ""
        #expect(vm.visibleItems.map(\.title) == ["go small", "xcode big"])
    }
}
