import Foundation
import Testing

@testable import Mackit

/// Tests for the incremental dedup index behind the scan merge.
///
/// The index replaced per-batch rebuilds of the id set, the path set and a
/// linear containment scan over every listed path; these pin the answers it
/// must give — above all the ancestor inversion that answers "is any
/// already-listed entry inside this path?" in one lookup.
struct ListedPathIndexTests {
    private func item(_ ruleID: String, _ path: String) -> JunkItem {
        JunkItem(ruleID: ruleID, title: "t", detail: "d", path: path,
                 category: .homebrew, risk: .safe)
    }

    @Test func idAndPathLookup() {
        var index = ListedPathIndex()
        index.insert(item("brew.cache", "/tmp/Library/Caches/Homebrew"))

        #expect(index.containsID("brew.cache::/tmp/Library/Caches/Homebrew"))
        #expect(!index.containsID("other::/tmp/Library/Caches/Homebrew"))
        #expect(index.containsPath("/tmp/Library/Caches/Homebrew"))
        #expect(!index.containsPath("/tmp/Library/Caches/Homebrew/foo"))
    }

    /// A listed path sits inside `P` exactly when `P` is one of its strict
    /// ancestors, so the ancestors are collected once and the query is a set
    /// lookup. The listed path itself, its own children and unrelated paths
    /// must all miss.
    @Test func containmentAnswersByAncestor() {
        var index = ListedPathIndex()
        index.insert(item("brew.cache", "/tmp/Library/Caches/Homebrew/foo--1.0"))

        #expect(index.containsPathInside("/tmp"))
        #expect(index.containsPathInside("/tmp/Library"))
        #expect(index.containsPathInside("/tmp/Library/Caches/Homebrew"))
        #expect(!index.containsPathInside("/tmp/Library/Caches/Homebrew/foo--1.0"))
        #expect(!index.containsPathInside("/tmp/Library/Caches/Homebrew/foo--1.0/bar"))
        #expect(!index.containsPathInside("/tmp/Library/Caches/HomebrewX"))
        #expect(!index.containsPathInside("/var"))
    }

    /// An absolute path's volume root is an ancestor too, and it is spelled
    /// "/" rather than the empty prefix the leading separator leaves.
    @Test func volumeRootCountsAsAncestor() {
        var index = ListedPathIndex()
        index.insert(item("r", "/a/b/c"))

        #expect(index.containsPathInside("/"))
        #expect(index.containsPathInside("/a"))
        #expect(index.containsPathInside("/a/b"))
    }

    /// A command-line item has no path: it must not poison the ancestor set
    /// (an empty-string query would otherwise match everything).
    @Test func emptyPathContributesNoAncestors() {
        var index = ListedPathIndex()
        index.insert(JunkItem(ruleID: "cli", title: "t", detail: "d", path: "",
                              category: .system, risk: .safe, isCommand: true,
                              command: ["brew", "cleanup"]))

        #expect(index.containsID("cli::cli"))
        #expect(index.containsPath(""))
        #expect(!index.containsPathInside(""))
        #expect(!index.containsPathInside("/"))
    }

    /// A rebuild after removal must answer exactly what the remaining items
    /// imply: the merge path rebuilds after every clean, and a stale index
    /// would silently drop or double-list paths.
    @Test func rebuildAfterRemovalDropsRemovedAncestors() {
        let kept = item("r2", "/a/b")
        let cleaned = item("r1", "/a/b/c")

        let before = ListedPathIndex(items: [kept, cleaned])
        #expect(before.containsPathInside("/a/b"))

        let after = ListedPathIndex(items: [kept])
        #expect(after.containsPathInside("/a"))
        #expect(!after.containsPathInside("/a/b"))
        #expect(!after.containsPath("/a/b/c"))
    }
}

/// The index is only correct if every mutation of the list keeps it in sync;
/// these drive the merge and removal paths that own that contract.
@MainActor
struct ListedPathIndexMergeTests {
    private func makeVM() -> AppViewModel { AppViewModel(statsPolling: false) }

    private func item(_ ruleID: String, _ path: String, size: Int64 = 10) -> JunkItem {
        JunkItem(ruleID: ruleID, title: "t", detail: "d", path: path,
                 category: .homebrew, risk: .safe, size: size)
    }

    /// The id set is cumulative across merges: the same rule finding the same
    /// path in a later phase must not re-list it.
    /// The id set is cumulative across merges: the same rule finding the same
    /// path in a later phase must not re-list it. (Path-level dedup across
    /// merges is already covered by `samePathIsOnlyListedOnce`; this is the
    /// id-level half.)
    @Test func idDedupSpansMerges() {
        let vm = makeVM()
        vm.mergeDiscovered([item("brew.cache", "/tmp/Caches/Homebrew")])
        vm.mergeDiscovered([item("brew.cache", "/tmp/Caches/Homebrew")])

        #expect(vm.items.count == 1)
        #expect(vm.totalSize == 10)
    }

    /// Within one batch the same path must not slip through twice either.
    @Test func pathDedupWithinBatch() {
        let vm = makeVM()
        vm.mergeDiscovered([
            item("brew.cache", "/tmp/Caches/Homebrew/foo", size: 10),
            item("app.junk", "/tmp/Caches/Homebrew/foo", size: 10),
        ])

        #expect(vm.items.count == 1)
    }

    /// A coarse entry listed *first* keeps the finer entries that come after
    /// it: the containment check only asks whether listed content sits inside
    /// the incoming path, never the other way round. (The coarser-loses
    /// direction is already covered by
    /// `coarserEntryNeverRelistsWhatFinerEntriesCover`.)
    @Test func coarseEntryFirstKeepsLaterFinerEntries() {
        let vm = makeVM()
        vm.mergeDiscovered([item("app.junk", "/tmp/Caches/Homebrew")])
        vm.mergeDiscovered([item("brew.cache", "/tmp/Caches/Homebrew/foo--1.0")])

        #expect(vm.items.count == 2)
    }

    /// After a clean removes items, the index must be rebuilt: merging the
    /// same path again has to list it, and an entry whose container was
    /// removed must no longer be swallowed.
    @Test func removalRebuildsTheIndex() {
        let vm = makeVM()
        vm.mergeDiscovered([
            item("brew.cache", "/tmp/Caches/Homebrew/foo--1.0"),
            item("brew.cache", "/tmp/Caches/Homebrew/bar--2.0"),
        ])

        vm.removeCleanedItems(Set(vm.items.map(\.id)))
        #expect(vm.items.isEmpty)

        vm.mergeDiscovered([item("app.junk", "/tmp/Caches/Homebrew")])
        #expect(vm.items.count == 1, "a path whose listed content was cleaned is listable again")
        #expect(vm.items.first?.ruleID == "app.junk")
    }

    /// The scan events' own append path feeds the same index, so a batch
    /// arriving through `apply(.discovered)` is deduplicated against later
    /// merges exactly like a merged batch.
    @Test func discoveredBatchFeedsTheIndex() {
        let vm = makeVM()
        vm.apply(.discovered([item("brew.cache", "/tmp/Caches/Homebrew/foo--1.0")]))
        vm.mergeDiscovered([item("app.junk", "/tmp/Caches/Homebrew")])

        #expect(vm.items.count == 1)
        #expect(vm.items.first?.ruleID == "brew.cache")
    }
}
