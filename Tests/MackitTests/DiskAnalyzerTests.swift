import Foundation
import Testing

@testable import Mackit

/// The disk analyzer measures one directory tree in a single pass and hands
/// the whole tree back when it is done. The fixture pins down the behaviors
/// the UI depends on: correct recursive sizes and direct-child counts, the
/// depth budget, and the skip rules — symlinked and `com.apple.*` children
/// (the latter would pop a TCC authorization dialog on macOS 26+), mount
/// points, and the TCC-protected home trio.
struct DiskAnalyzerTests {
    private func write(size: Int, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: size).write(to: url)
    }

    /// base/
    ///   big/           1 MB + 1 MB + nested/1 MB   → 1 folder, 2 files, ~3 MB
    ///   small/         1 KB                        → 0 folders, 1 file
    ///   root.bin       2 MB                        → a plain file
    ///   com.apple.Music/                           → skipped (TCC-protected)
    ///   link → big/                                → skipped (symlink)
    private func makeFixture() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-disk-analyzer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let mb = 1024 * 1024
        try write(size: mb, at: base.appendingPathComponent("big/a.bin"))
        try write(size: mb, at: base.appendingPathComponent("big/b.bin"))
        try write(size: mb, at: base.appendingPathComponent("big/nested/c.bin"))
        try write(size: 1024, at: base.appendingPathComponent("small/d.bin"))
        try write(size: 2 * mb, at: base.appendingPathComponent("root.bin"))
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("com.apple.Music"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: base.appendingPathComponent("link").path,
            withDestinationPath: base.appendingPathComponent("big").path
        )
        return base
    }

    /// Runs a scan to completion and returns the progress-event count, the
    /// finished tree, and the directory count the finished event carries.
    private func scan(
        root: String,
        maxDepth: Int = DiskAnalyzer.maxDepth,
        protectedPaths: Set<String> = []
    ) async -> (progressEvents: Int, node: DiskEntry?, directories: Int) {
        var progressEvents = 0
        var node: DiskEntry?
        var directories = 0
        for await event in DiskAnalyzer.scan(root: root, protectedPaths: protectedPaths, maxDepth: maxDepth) {
            switch event {
            case .progress:
                progressEvents += 1
            case .finished(let finished, let finishedDirectories):
                #expect(node == nil, "the tree is published exactly once, at the end")
                node = finished
                directories = finishedDirectories
            }
        }
        return (progressEvents, node, directories)
    }

    @Test func scanMeasuresTheWholeTreeAndPublishesItOnce() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let (progressEvents, node, directories) = await scan(root: base.path)
        let root = try #require(node)
        #expect(progressEvents > 0, "progress events precede the finished tree")
        // The finished event carries the exact count: the progress events are
        // throttled, so the last of them can lag behind the real total, and
        // the caller divides by this number on the next scan.
        #expect(directories == 4, "base, big, big/nested and small are the four measured directories")
        #expect(root.path == base.path)
        #expect(root.name == base.lastPathComponent)
        #expect(root.isDirectory)

        // Size descending; the symlink and the com.apple.* child are absent.
        #expect(root.children.map(\.name) == ["big", "root.bin", "small"])
        #expect(root.folderCount == 2)
        #expect(root.fileCount == 1)
        #expect(root.itemCount == 3)
        // 3 MB + 2 MB + small's 1 KB, allowing for filesystem block rounding.
        #expect(root.size > 4_900_000)
        #expect(root.size < 5_300_000)
        #expect(!root.isTruncated)
        #expect(!root.isUnreadable)
        #expect(!root.isSkipped)

        let big = try #require(root.children.first)
        #expect(big.isDirectory)
        #expect(big.folderCount == 1, "big contains nested/")
        #expect(big.fileCount == 2, "big contains a.bin and b.bin")
        #expect(big.itemCount == 3)
        #expect(big.size > 2_900_000)
        #expect(big.size < 3_200_000)
        // Equal sizes fall back to name ascending, so the order is
        // deterministic rather than a coin flip among the 1 MB children.
        #expect(big.children.map(\.name) == ["a.bin", "b.bin", "nested"])
        #expect(big.children.first?.isDirectory == false)

        let small = try #require(root.children.last)
        #expect(small.folderCount == 0)
        #expect(small.fileCount == 1)

        let file = try #require(root.children.first { $0.name == "root.bin" })
        #expect(!file.isDirectory)
        #expect(file.children.isEmpty)
        #expect(file.size > 1_900_000)
    }

    /// The depth budget bounds how many levels of nodes are retained, not how
    /// deep the measurement goes: a truncated folder's size and counts are
    /// still real, only its children are missing.
    @Test func truncatesBeyondTheDepthBudget() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let (_, node, _) = await scan(root: base.path, maxDepth: 1)
        let root = try #require(node)
        #expect(root.children.map(\.name) == ["big", "root.bin", "small"])

        let big = try #require(root.children.first)
        #expect(big.isTruncated)
        #expect(big.children.isEmpty, "children past the budget are not retained")
        #expect(big.folderCount == 1, "the cut level is still enumerated")
        #expect(big.fileCount == 2)
        #expect(big.size > 2_900_000, "the size is measured past the budget")
    }

    /// A folder the process may not read enumerates as empty once access is
    /// refused (a denied TCC prompt, or a locked directory). It must be
    /// marked unreadable — reporting "0 B" for a real folder is a lie the user
    /// would act on.
    @Test func unreadableChildIsMarkedInsteadOfReportingZeroBytes() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let locked = base.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let (_, node, _) = await scan(root: base.path)
        let root = try #require(node)
        let entry = try #require(root.children.first { $0.name == "locked" })
        #expect(entry.isUnreadable)
        #expect(entry.size == 0)
        #expect(entry.children.isEmpty)
        #expect(entry.itemCount == 0)
        // Readable siblings are unaffected.
        #expect(root.children.first { $0.name == "big" }?.isUnreadable == false)
        #expect(root.children.first { $0.name == "small" }?.isUnreadable == false)
    }

    /// The TCC-protected home trio is listed as skipped and left unmeasured:
    /// entering one pops the access dialog, so a full-disk scan must not
    /// traverse it.
    @Test func protectedPathsAreListedAsSkippedAndNotMeasured() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(size: 64 * 1024, at: base.appendingPathComponent("small/d.bin"))

        let (_, node, _) = await scan(
            root: base.path,
            protectedPaths: [base.appendingPathComponent("small").path]
        )
        let root = try #require(node)
        let small = try #require(root.children.first { $0.name == "small" })
        #expect(small.isSkipped)
        #expect(small.size == 0, "a skipped folder is never measured")
        #expect(small.children.isEmpty)
        // The root total is exactly its measured children's: the skipped
        // folder's 64 KB payload is not counted anywhere.
        let measured = root.children.filter { $0.name != "small" }.reduce(Int64(0)) { $0 + $1.size }
        #expect(root.size == measured)
    }

    /// The counting pass is the denominator the progress fraction divides by,
    /// so it must visit exactly the directories the measurement visits — a
    /// count that disagreed would leave the fraction short of 100% and the
    /// remaining estimate short of the truth.
    @Test func theCountPassVisitsExactlyWhatTheScanVisits() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let (_, node, scanned) = await scan(root: base.path)
        #expect(node != nil)
        let counted = await DiskAnalyzer.countDirectories(root: base.path, protectedPaths: [])
        #expect(counted == scanned, "the count must match the directories the scan visits")

        // A protected folder is listed but never entered, so it is in neither
        // count — the denominator drops with it.
        let protected = Set([base.appendingPathComponent("small").path])
        let (_, protectedNode, protectedScanned) = await scan(root: base.path, protectedPaths: protected)
        #expect(protectedNode != nil)
        let protectedCounted = await DiskAnalyzer.countDirectories(root: base.path, protectedPaths: protected)
        #expect(protectedCounted == protectedScanned)
        #expect(protectedCounted == counted - 1, "the skipped folder leaves both counts")
    }

    /// A path that cannot be enumerated at all — missing, or denied — comes
    /// back as a flagged node rather than an empty one, so the page can say
    /// "can't read" instead of "empty folder".
    @Test func missingRootComesBackFlagged() async {
        let (progressEvents, node, _) = await scan(root: "/definitely/not/a/real/path")
        #expect(progressEvents >= 1)
        let root = try? #require(node)
        #expect(root?.isUnreadable == true)
        #expect(root?.children.isEmpty == true)
    }

    /// A symlink is neither followed nor counted — including one that points
    /// back at its own parent.
    ///
    /// The shared fixture already pins that a symlinked folder is left out of
    /// the listing; this adds the two things that would actually corrupt a
    /// number: a cycle (a walk that follows links never terminates) and
    /// double-counting (the same bytes reached twice through two paths).
    @Test func symbolicLinksAreNeitherFollowedNorCounted() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-links-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try Data(repeating: 0, count: 64 * 1024).write(to: real.appendingPathComponent("payload.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: base.appendingPathComponent("alias").path,
            withDestinationPath: real.path
        )
        // A cycle: a link inside the folder pointing back at its own parent.
        try FileManager.default.createSymbolicLink(
            atPath: real.appendingPathComponent("back").path,
            withDestinationPath: base.path
        )

        let (_, node, _) = await scan(root: base.path)
        let root = try #require(node)
        #expect(root.children.map(\.name) == ["real"], "only the real folder is listed")

        let realNode = try #require(root.children.first)
        #expect(realNode.children.map(\.name) == ["payload.bin"], "the cyclic link is dropped")
        // The payload is counted exactly once: through `real`, never again
        // through `alias`.
        #expect(root.size == realNode.size)
        #expect(realNode.size >= 64 * 1024)
    }

    /// Children come back size-descending, and a tie breaks on the name so the
    /// list and the treemap never flip two equal entries between renders.
    @Test func childrenSortBySizeThenName() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-sort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Equal sizes, written in reverse alphabetical order.
        for name in ["c.bin", "b.bin", "a.bin"] {
            try Data(repeating: 0, count: 16 * 1024).write(to: base.appendingPathComponent(name))
        }
        try Data(repeating: 0, count: 256 * 1024).write(to: base.appendingPathComponent("big.bin"))

        let (_, node, _) = await scan(root: base.path)
        let root = try #require(node)
        #expect(root.children.map(\.name) == ["big.bin", "a.bin", "b.bin", "c.bin"])
        #expect(root.fileCount == 4)
        #expect(root.folderCount == 0)
    }
}
