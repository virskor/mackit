import Foundation

/// List sort comparator: sort field + direction.
///
/// Three places share this single type, so the sort semantics have only one source:
/// - `ItemListView` binds it to `Table(sortOrder:)`: when the user clicks a header,
///   SwiftUI writes this value directly (including flipping ascending/descending) and
///   handles drawing the header arrow;
/// - `ContentToolbarRow`'s sort menu writes the `ItemSort` preset values;
/// - `AppViewModel.filterAndSort()` uses it to sort the visible list—SwiftUI's
///   `Table(sortOrder:)` only updates the binding and the arrow; it does not sort the
///   data itself.
///
/// The semantics correspond word for word to the historical `ItemSort`: names in natural
/// order (file2 sorts before file10), sizes compared numerically, and a missing
/// modification time treated as the earliest.
struct JunkItemComparator: SortComparator, Hashable {
    enum Field: Hashable, Sendable {
        case name
        case size
        case modified
    }

    var field: Field
    var order: SortOrder

    func compare(_ lhs: JunkItem, _ rhs: JunkItem) -> ComparisonResult {
        switch field {
        case .name:
            return lhs.title.localizedStandardCompare(rhs.title)
        case .size:
            if lhs.size == rhs.size { return .orderedSame }
            return lhs.size < rhs.size ? .orderedAscending : .orderedDescending
        case .modified:
            let l = lhs.modified ?? .distantPast
            let r = rhs.modified ?? .distantPast
            if l == r { return .orderedSame }
            return l < r ? .orderedAscending : .orderedDescending
        }
    }

    /// Determines order by the comparator's own direction. A header click flips `order`,
    /// and the sort must flip with it, otherwise the arrow direction and the actual row
    /// order will be opposite.
    func sorts(_ lhs: JunkItem, before rhs: JunkItem) -> Bool {
        let result = compare(lhs, rhs)
        return order == .forward ? result == .orderedAscending : result == .orderedDescending
    }
}
