import Foundation

/// An incrementally-maintained index over the paths the cleanup list has
/// already accepted, answering the dedup questions a scan phase asks per
/// incoming item.
///
/// Rebuilding this per merge batch was the cost the index removes: `items`
/// holds thousands of entries and every scan phase merges hundreds more, so
/// the id set, the path set and — worst of all — the containment scan (a
/// linear pass over every listed path, per incoming item) were recomputed
/// from scratch on each merge, on the main actor.
///
/// The containment question — "is any already-listed entry inside this
/// path?" — is answered by inverting it: a listed path sits inside `P`
/// exactly when `P` is one of its strict ancestors, so the ancestors of
/// every listed path are collected once, as paths are appended, and a query
/// is a single set lookup. A rebuild (`init(items:)`) is only needed after
/// removals, which cannot be applied to a set incrementally.
///
/// Keeping the index in sync is the caller's contract: every append to the
/// list goes through `insert(contentsOf:)`, and every removal or reset
/// rebuilds it. A stale index would silently mis-dedup — items dropped that
/// should have been listed, or the same bytes listed twice.
struct ListedPathIndex {
    private var ids: Set<String> = []
    private var paths: Set<String> = []
    /// Every strict ancestor directory of every listed path: "/a/b/c"
    /// contributes "/a" and "/a/b". A listed path is inside `P` exactly when
    /// `P` is in this set.
    private var ancestors: Set<String> = []

    /// Index the given items — the initial state, and the rebuild after a
    /// removal or reset.
    init(items: [JunkItem] = []) {
        insert(contentsOf: items)
    }

    /// Record newly listed items.
    mutating func insert(contentsOf newItems: [JunkItem]) {
        for item in newItems {
            insert(item)
        }
    }

    /// Record one newly listed item.
    mutating func insert(_ item: JunkItem) {
        ids.insert(item.id)
        paths.insert(item.path)
        guard !item.path.isEmpty else { return }
        // "/a/b/c" → "/", "/a", "/a/b". Built by walking the separator
        // positions so each ancestor is one prefix slice; siblings share
        // ancestors, but a set keeps only one copy. The leading slash's
        // prefix is the volume root itself, spelled "/" rather than "".
        var cursor = item.path.startIndex
        while let slash = item.path[cursor...].firstIndex(of: "/") {
            let prefix = String(item.path[..<slash])
            ancestors.insert(prefix.isEmpty ? "/" : prefix)
            cursor = item.path.index(after: slash)
        }
    }

    /// Whether an item with this id is already listed.
    func containsID(_ id: String) -> Bool {
        ids.contains(id)
    }

    /// Whether this exact path is already listed.
    func containsPath(_ path: String) -> Bool {
        paths.contains(path)
    }

    /// Whether any already-listed entry sits inside `path` — i.e. whether
    /// cleaning `path` would also delete entries the list already shows
    /// separately.
    func containsPathInside(_ path: String) -> Bool {
        ancestors.contains(path)
    }
}
