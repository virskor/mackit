import AppKit
import Darwin
import Foundation
import Testing

@testable import Mackit

/// Regression coverage written while reviewing the disk analysis branch.
///
/// The branch's own suites pin the headline behaviors; these tests target the
/// seams a review flags as under-covered or as invariants nothing asserted:
/// the enumeration skip rules the counting pass shares with the measurement,
/// the depth budget's exact boundary, progress throttling and cancellation
/// contracts of the analyzer stream, the treemap's fold bookkeeping, the
/// progress history's keying, the icon cache, and the tree invariants a
/// subtree graft has to preserve (ordering and ancestor totals).
///
/// Everything here is fixture-backed or pure: no window is opened, no scan of
/// the real startup disk runs, and the only real path touched is the volume
/// root's own listing in `directoriesSkipsMountPointsAtTheVolumeRoot`.
struct DiskAnalysisReviewTests {
    private func write(size: Int, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: size).write(to: url)
    }

    private func makeBase(_ label: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-review-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Runs a scan to completion, collecting the events in order.
    private func scan(
        root: String,
        maxDepth: Int = DiskAnalyzer.maxDepth,
        protectedPaths: Set<String> = []
    ) async -> (events: [DiskScanEvent], node: DiskEntry?, directories: Int) {
        var events: [DiskScanEvent] = []
        var node: DiskEntry?
        var directories = 0
        for await event in DiskAnalyzer.scan(root: root, protectedPaths: protectedPaths, maxDepth: maxDepth) {
            events.append(event)
            if case .finished(let finished, let count) = event {
                node = finished
                directories = count
            }
        }
        return (events, node, directories)
    }

    // MARK: - Enumeration skip rules

    /// `directories(of:)` is the counting pass's enumeration, and the counting
    /// pass exists only to agree with the measurement. Both must select the
    /// same children: the same directories, no symlinks, nothing unreadable.
    @Test func directoriesAgreeWithEntriesOnWhichChildrenAreDirectories() async throws {
        let base = try makeBase("agree")
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createDirectory(at: base.appendingPathComponent("one"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("two"), withIntermediateDirectories: true)
        try write(size: 8, at: base.appendingPathComponent("file.bin"))
        try write(size: 8, at: base.appendingPathComponent("other.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: base.appendingPathComponent("alias").path,
            withDestinationPath: base.appendingPathComponent("one").path
        )

        let directories = try #require(FileSystem.directories(of: base.path))
        let entries = try #require(FileSystem.entries(of: base.path))
        let entryDirectories = entries.filter(\.isDirectory).map(\.path).sorted()

        #expect(directories.sorted() == entryDirectories, "the two enumerations must select the same directories")
        #expect(!directories.contains { $0.hasSuffix("alias") }, "a symlinked directory is not a directory to walk")
        #expect(!directories.contains { $0.hasSuffix(".bin") }, "files are not directories")
    }

    /// An unreadable directory is nil, not an empty list: the counting pass
    /// treats it as "not entered", exactly as the measurement flags it.
    @Test func directoriesReturnNilForAnUnreadableDirectory() throws {
        let base = try makeBase("denied")
        defer { try? FileManager.default.removeItem(at: base) }
        let locked = base.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        #expect(FileSystem.directories(of: locked.path) == nil)
        #expect(FileSystem.entries(of: locked.path) == nil)
        // The parent's own listing is unaffected: a denied child is still a
        // child, and a file is not a directory.
        #expect(FileSystem.directories(of: base.path) == [locked.path])
        try write(size: 8, at: base.appendingPathComponent("f.bin"))
        #expect(FileSystem.directories(of: base.appendingPathComponent("f.bin").path) == nil)
    }

    /// Mount points are another volume's root: listing one would show a
    /// near-empty row for a volume that holds half the disk, so the walk skips
    /// it. `/dev` is a devfs mount on every macOS, which makes it a stable
    /// anchor for the rule at the volume root.
    @Test func directoriesSkipsMountPointsAtTheVolumeRoot() throws {
        let top = try #require(FileSystem.directories(of: "/"))
        #expect(top.contains("/dev") == false, "the /dev mount point must not be walked into")

        // The property, not just the one known case: nothing the walk returns
        // may be a mount point of its own.
        for path in top {
            var stats = statfs()
            guard statfs(path, &stats) == 0 else { continue }
            let mountedOn = withUnsafePointer(to: &stats.f_mntonname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
            }
            #expect(mountedOn != path, "\(path) is a mount point and must be skipped")
        }
    }

    // MARK: - Volume-root plumbing markers

    /// The firmlink marker dirs and the `.file` placeholder are filesystem
    /// plumbing: on macOS 26+ `.nofollow` mirrors the whole volume root, so
    /// traversing one would count every byte on the disk a second time. The
    /// rule is by name at any depth.
    @Test func volumeRootPlumbingMarkersAreSkippedAtAnyDepth() async throws {
        let base = try makeBase("markers")
        defer { try? FileManager.default.removeItem(at: base) }

        // A marker directory carrying payload, a marker file, and one nested
        // a level down — all four names, so a renamed marker cannot slip by.
        try write(size: 512 * 1024, at: base.appendingPathComponent(".nofollow/payload.bin"))
        try write(size: 256 * 1024, at: base.appendingPathComponent(".file"))
        try FileManager.default.createDirectory(at: base.appendingPathComponent(".resolve"), withIntermediateDirectories: true)
        try write(size: 128 * 1024, at: base.appendingPathComponent(".vol/payload.bin"))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("plain"), withIntermediateDirectories: true)
        try write(size: 512 * 1024, at: base.appendingPathComponent("plain/.nofollow/payload.bin"))

        let (_, node, directories) = await scan(root: base.path)
        let root = try #require(node)
        #expect(root.children.map(\.name) == ["plain"], "no marker may be listed, got \(root.children.map(\.name))")
        #expect(root.folderCount == 1, "markers are not folders to the user")
        #expect(root.fileCount == 0)
        // base, plain — the markers' payloads were never visited or counted.
        #expect(directories == 2, "markers are not walked, so they are not counted: \(directories)")
        #expect(root.size == 0, "no payload was measured: \(root.size)")

        let plain = try #require(root.children.first)
        #expect(plain.children.isEmpty, "the nested marker is skipped too")
        #expect(plain.folderCount == 0)
        #expect(plain.fileCount == 0)
    }

    // MARK: - Depth budget boundary

    /// The default budget retains six levels below the root and measures
    /// deeper: the seventh level is the first truncated one — listed with real
    /// counts and a real size, but without children.
    @Test func theDefaultDepthBudgetRetainsExactlySixLevels() async throws {
        let base = try makeBase("depth")
        defer { try? FileManager.default.removeItem(at: base) }
        let levels = 9
        var url = base
        for level in 0..<levels {
            url = url.appendingPathComponent("d\(level)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try write(size: 1024, at: url.appendingPathComponent("f.bin"))
        }

        let (_, node, _) = await scan(root: base.path)
        var current = try #require(node)
        // Walk to depth 5 (root is depth 0): every level on the way retains.
        for depth in 1...5 {
            let next = try #require(current.children.first, "depth \(depth) must retain its child")
            #expect(!next.isTruncated, "depth \(depth) is inside the budget")
            #expect(next.children.isEmpty == false, "depth \(depth) retains its children")
            current = next
        }
        // Depth 6 is the boundary: measured, enumerated, not retained.
        let boundary = try #require(current.children.first)
        #expect(boundary.isTruncated, "depth 6 is past the budget")
        #expect(boundary.children.isEmpty)
        #expect(boundary.folderCount == 1, "the level past the budget is still enumerated")
        #expect(boundary.fileCount == 1)
        #expect(boundary.size >= 1024, "the size is measured past the budget")
    }

    // MARK: - Analyzer stream contract

    /// An empty directory is an empty tree, not an unreadable one: the page
    /// says "empty folder" for it and "can't read" only for a denial.
    @Test func scanningAnEmptyDirectoryYieldsAnEmptyTree() async throws {
        let base = try makeBase("empty")
        defer { try? FileManager.default.removeItem(at: base) }

        let (events, node, directories) = await scan(root: base.path)
        let root = try #require(node)
        #expect(root.children.isEmpty)
        #expect(root.folderCount == 0)
        #expect(root.fileCount == 0)
        #expect(root.size == 0)
        #expect(!root.isUnreadable)
        #expect(!root.isTruncated)
        #expect(!root.isSkipped)
        #expect(directories == 1, "the root itself is the one measured directory")
        #expect(events.contains { if case .finished = $0 { true } else { false } })
    }

    /// A file is not a directory: enumerating one fails, and the failure is
    /// flagged rather than presented as a measured empty folder.
    @Test func scanningAFileAsRootIsFlaggedUnreadable() async throws {
        let base = try makeBase("fileroot")
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("payload.bin")
        try write(size: 64 * 1024, at: file)

        let (_, node, directories) = await scan(root: file.path)
        let root = try #require(node)
        #expect(root.isUnreadable, "a file cannot be enumerated as a directory")
        #expect(root.children.isEmpty)
        #expect(root.size == 0)
        #expect(directories == 1, "the failed root still counts as one visited directory")
    }

    /// Progress events are throttled: one per directory would wake the main
    /// actor thousands of times a second for a label that changes too fast to
    /// read. The count of events must stay well under the directory count.
    @Test(.serialized)
    func progressEventsAreThrottledAndStayInsideTheTree() async throws {
        let base = try makeBase("throttle")
        defer { try? FileManager.default.removeItem(at: base) }
        try makeWideTree(at: base, fanout: 10, depth: 3)

        let (events, node, directories) = await scan(root: base.path)
        let root = try #require(node)
        let progress = events.compactMap { event -> String? in
            guard case .progress(_, let current) = event else { return nil }
            return current
        }
        #expect(directories > 1_000, "the fixture must be wide enough to matter: \(directories)")
        #expect(progress.isEmpty == false, "at least one progress event precedes the tree")
        #expect(
            progress.count < directories,
            "\(progress.count) events for \(directories) directories — the throttle is gone"
        )
        for path in progress {
            #expect(path == base.path || path.hasPrefix(base.path + "/"), "\(path) is outside the scanned tree")
        }
    }

    // MARK: - Treemap fold bookkeeping

    /// The folded ids keep the caller's order — the model hands children over
    /// size-descending, and the popover lists every merged child in that same
    /// order.
    @Test func foldedIdsKeepTheCallersOrder() {
        let items: [(id: String, size: Int64)] = [
            ("big", 90), ("t1", 1), ("t2", 2), ("t3", 3), ("tiny", 1)
        ]
        let map = TreemapLayout.layout(
            items: items,
            in: CGSize(width: 300, height: 200),
            minTileArea: 2_400
        )
        guard let overflow = map.overflow else {
            Issue.record("expected a folded tail")
            return
        }
        #expect(overflow.ids == ["t1", "t2", "t3", "tiny"], "folded ids must keep the caller's order")
        #expect(overflow.size == 7)
        #expect(map.rects.keys.sorted() == ["big"])
    }

    /// Zero-size entries are not drawn, and they must not inflate the
    /// denominator either: the share a tile reports is its size over the
    /// measured total, and empty folders contribute nothing to either.
    @Test func zeroSizeItemsDoNotInflateTheTotal() {
        let items: [(id: String, size: Int64)] = [("a", 10), ("empty1", 0), ("empty2", 0)]
        let map = TreemapLayout.layout(items: items, in: CGSize(width: 300, height: 200), minTileArea: 2_400)
        #expect(map.totalSize == 10, "zero-size items must not enter the total: \(map.totalSize)")
        #expect(map.rects.keys.sorted() == ["a"])
        #expect(map.overflow == nil, "a lone measured child is not a folded tail")
    }

    /// The aggregate tile's sentinel id is internal: a real path can never
    /// collide with it, and it must never leak into the rects a view iterates.
    @Test func theAggregateSentinelNeverLeaksIntoTheRects() {
        var items: [(id: String, size: Int64)] = [("big", 80)]
        items.append(contentsOf: (1...6).map { (id: "t\($0)", size: 1) })
        let map = TreemapLayout.layout(items: items, in: CGSize(width: 300, height: 200), minTileArea: 2_400)
        #expect(map.overflow != nil)
        #expect(map.rects.count == 1, "only the head keeps a rect: \(map.rects.keys)")
        for key in map.rects.keys {
            #expect(!key.contains("\u{0}"), "the aggregate sentinel leaked into the rects")
        }
        // The aggregate's own rect is the tail's area, inside the container.
        guard let rect = map.overflow?.rect else {
            Issue.record("expected the aggregate tile's rect")
            return
        }
        #expect(rect.minX >= -0.5 && rect.minY >= -0.5)
        #expect(rect.maxX <= 300.5 && rect.maxY <= 200.5)
    }

    // MARK: - Progress history

    /// The remembered count is the denominator a rescan divides by, so its
    /// keying has to be exact: same tree and same skip set, and nothing else.
    @Test func progressHistoryKeysOnRootAndSkipSignature() throws {
        let domain = "mackit-review-history-\(UUID().uuidString)"
        let history = ScanProgressHistory(defaults: UserDefaults(suiteName: domain)!)
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        #expect(history.directoryCount(for: "/tmp/tree", signature: "sig") == nil, "nothing remembered yet")
        history.record(root: "/tmp/tree", signature: "sig", directories: 42)
        #expect(history.directoryCount(for: "/tmp/tree", signature: "sig") == 42)
        // A different skip set visits different directories, so the old count
        // must not be reused as this scan's denominator.
        #expect(history.directoryCount(for: "/tmp/tree", signature: "other") == nil)
        #expect(history.directoryCount(for: "/tmp/other", signature: "sig") == nil)
        // A zero count is not a denominator.
        history.record(root: "/tmp/zero", signature: "sig", directories: 0)
        #expect(history.directoryCount(for: "/tmp/zero", signature: "sig") == nil)
        // The newest count wins.
        history.record(root: "/tmp/tree", signature: "sig", directories: 7)
        #expect(history.directoryCount(for: "/tmp/tree", signature: "sig") == 7)
    }

    // MARK: - Icon cache

    /// The cache exists because `NSWorkspace.icon` is not free and the list
    /// re-renders on every observation change: the same path must hand back
    /// the very same image, not an equal one.
    @Test
    @MainActor
    func iconCacheHandsBackTheSameImageForTheSamePath() throws {
        let base = try makeBase("icons")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let model = DiskAnalysisModel(rootPath: base.path)

        let first = model.icon(forPath: base.appendingPathComponent("folder").path)
        let second = model.icon(forPath: base.appendingPathComponent("folder").path)
        #expect(first === second, "a cached icon must be the same instance, not a rebuild")
        // A different path is its own entry.
        let other = model.icon(forPath: base.path)
        #expect(other !== first, "distinct paths are cached separately")
    }

    // MARK: - Graft invariants

    /// Fixture: a home folder whose TCC-protected child is skipped by the
    /// default scan, with one plain file beside it.
    private func makeHomeFixture() throws -> (base: URL, home: URL) {
        let base = try makeBase("graft")
        let home = base.appendingPathComponent("home")
        try write(size: 64 * 1024, at: home.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Documents"),
            withIntermediateDirectories: true
        )
        return (base, home)
    }

    /// Promoting a skipped folder measures real bytes that every ancestor's
    /// total was computed without. The graft has to carry that delta up the
    /// spine, or the rows above keep claiming a total that no longer adds up
    /// to what their own children show.
    @Test
    @MainActor
    func promotingASkippedFolderUpdatesEveryAncestorsTotal() async throws {
        let (base, home) = try makeHomeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(size: 1024 * 1024, at: home.appendingPathComponent("Documents/report.pdf"))

        let model = DiskAnalysisModel(rootPath: base.path, homePath: home.path)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()
        model.goToHome()
        await model.waitUntilSettled()

        let documents = try #require(model.children.first { $0.name == "Documents" })
        #expect(documents.isSkipped)
        #expect(documents.size == 0, "a skipped folder is never measured")
        let homeBefore = try #require(model.currentEntry)
        #expect(homeBefore.size == homeBefore.children.reduce(Int64(0)) { $0 + $1.size })

        model.scanFolder(documents)
        await model.waitUntilSettled()

        // The promoted row carries its measured size, and the levels above
        // add up to their children again.
        let promoted = try #require(model.children.first { $0.name == "Documents" })
        #expect(promoted.isSkipped == false)
        #expect(promoted.size >= 1024 * 1024)
        let homeAfter = try #require(model.currentEntry)
        #expect(
            homeAfter.size == homeAfter.children.reduce(Int64(0)) { $0 + $1.size },
            "the home total must add up to its children after the graft: \(homeAfter.size)"
        )
        #expect(homeAfter.size > homeBefore.size, "the home total must grow with the promoted folder")

        // And so must the root, two levels up.
        model.navigateToBreadcrumb(index: 0)
        let root = try #require(model.currentEntry)
        #expect(
            root.size == root.children.reduce(Int64(0)) { $0 + $1.size },
            "the root total must add up to its children after the graft: \(root.size)"
        )
        #expect(root.size > 0)
    }

    /// A grafted subtree can outgrow the sibling it is listed behind, so the
    /// published listing must stay size-descending — that order is what the
    /// list shows and what "select the largest child" assumes.
    @Test
    @MainActor
    func theListingStaysSizeDescendingAfterAGraft() async throws {
        let (base, home) = try makeHomeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(size: 1024 * 1024, at: home.appendingPathComponent("Documents/report.pdf"))

        let model = DiskAnalysisModel(rootPath: base.path, homePath: home.path)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()
        model.goToHome()
        await model.waitUntilSettled()

        // Before the promotion the plain file is the largest child.
        #expect(model.children.first?.name == "notes.txt")
        let documents = try #require(model.children.first { $0.name == "Documents" })
        model.scanFolder(documents)
        await model.waitUntilSettled()

        // Afterwards Documents is the largest, so it leads the listing.
        #expect(model.children.first?.name == "Documents", "the largest child must come first")
        let sizes = model.children.map(\.size)
        #expect(sizes == sizes.sorted(by: >), "the listing must stay size-descending: \(sizes)")
    }

    // MARK: - Helpers

    /// A wide, shallow tree: many directories, no payload.
    private func makeWideTree(at base: URL, fanout: Int, depth: Int) throws {
        func build(_ url: URL, level: Int) throws {
            guard level < depth else { return }
            for index in 0..<fanout {
                let child = url.appendingPathComponent("d\(level)-\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
                try build(child, level: level + 1)
            }
        }
        try build(base, level: 0)
    }
}
