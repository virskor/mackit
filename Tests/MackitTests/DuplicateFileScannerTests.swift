import Foundation
import Testing

@testable import Mackit

/// The duplicate scanner compares file contents under one directory tree and
/// reports groups of byte-identical files. The fixture pins down the
/// behaviors the page depends on: grouping only on full-content agreement
/// (same size and same head digest are candidates, never a verdict), the
/// threshold filter, the logical-size bucketing that keeps copies with
/// different allocations comparable, the skip rules — symlinks, bundles and
/// document packages never entered, `com.apple.*` system data, the
/// protected-path set, the Trash, multi-link files — and the counts the
/// finished event carries.
@Suite(.serialized)
struct DuplicateFileScannerTests {
    /// The threshold the fixture is built around. Small on purpose: the
    /// pipeline's logic does not care about absolute sizes, and a scan's
    /// cost is IO this suite should not add to.
    private let threshold = Int64(100_000)

    /// 120 KB of content; every file of this logical size is bucketed
    /// together regardless of how many blocks it actually allocates.
    private let payloadSize = 120_000

    private func write(_ payload: Data, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: url)
    }

    /// A file of `size` zero bytes backed by no allocated blocks. Used to
    /// prove the walk buckets by content size rather than allocation.
    private func writeSparse(size: Int, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            Issue.record("could not create \(url.path)")
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
    }

    /// Two distinct 120 KB payloads, and one 200 KB prefix shared by two
    /// files whose tails differ — the case that separates a head digest from
    /// a verdict.
    private func payload(_ byte: UInt8, size: Int) -> Data {
        Data(repeating: byte, count: size)
    }

    /// base/
    ///   alpha/a.bin  120 KB payload P            ┐
    ///   alpha/b.bin  120 KB payload P            ├ one group of four*
    ///   beta/c.bin   120 KB payload P            │
    ///   protected/k.bin payload P                ┘ (*without protectedPaths)
    ///   beta/d.bin   120 KB payload Q            → same size, not grouped
    ///   tiny/x,y     1 KB payload P              → below the threshold
    ///   headfake/e,f 200 KB, shared 100 KB head  → same head, not grouped
    ///   hard/g.bin   payload P + hard link h     → multi-link, skipped
    ///   bundle/Tool.app/Contents/i.bin payload P → bundle never entered
    ///   pages/Report.pages/Contents/p.bin payload P → document package never entered
    ///   repo/.git/config             payload P   → version-control metadata never entered
    ///   com.apple.Music/j.bin payload P          → skipped (TCC-protected)
    ///   link → alpha                             → skipped (symlink)
    private func makeFixture() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-duplicate-\(UUID().uuidString)", isDirectory: true)
        let p = payload(0xAA, size: payloadSize)
        let q = payload(0xBB, size: payloadSize)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try write(p, at: base.appendingPathComponent("alpha/a.bin"))
        try write(p, at: base.appendingPathComponent("alpha/b.bin"))
        try write(p, at: base.appendingPathComponent("beta/c.bin"))
        try write(q, at: base.appendingPathComponent("beta/d.bin"))
        // Same content as the group above, but 1 KB: the threshold is
        // applied during the walk, so content equality never rescues a file
        // that never became a candidate.
        try write(payload(0xAA, size: 1_000), at: base.appendingPathComponent("tiny/x.bin"))
        try write(payload(0xAA, size: 1_000), at: base.appendingPathComponent("tiny/y.bin"))

        // Same size, same first 100 KB (well past the 64 KiB head window),
        // different tails.
        let head = payload(0xCC, size: 100_000)
        try write(head + payload(0x11, size: 100_000), at: base.appendingPathComponent("headfake/e.bin"))
        try write(head + payload(0x22, size: 100_000), at: base.appendingPathComponent("headfake/f.bin"))

        try write(p, at: base.appendingPathComponent("hard/g.bin"))
        try FileManager.default.linkItem(
            atPath: base.appendingPathComponent("hard/g.bin").path,
            toPath: base.appendingPathComponent("hard/h.bin").path
        )

        try write(p, at: base.appendingPathComponent("bundle/Tool.app/Contents/i.bin"))
        try write(p, at: base.appendingPathComponent("pages/Report.pages/Contents/p.bin"))
        try write(p, at: base.appendingPathComponent("repo/.git/config"))
        try write(p, at: base.appendingPathComponent("com.apple.Music/j.bin"))
        try write(p, at: base.appendingPathComponent("protected/k.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: base.appendingPathComponent("link").path,
            withDestinationPath: base.appendingPathComponent("alpha").path
        )
        return base
    }

    /// Runs a scan to completion and returns the groups, the walk-progress
    /// and hashing event counts, and the finished event's counts.
    private func scan(
        root: String,
        threshold: Int64,
        protectedPaths: Set<String> = [],
        trashDirectory: URL? = nil
    ) async -> (
        groups: [DuplicateGroup],
        progressEvents: Int,
        hashingEvents: Int,
        unreadable: Int,
        skippedLinked: Int
    ) {
        var groups: [DuplicateGroup] = []
        var progressEvents = 0
        var hashingEvents = 0
        var unreadable = 0
        var skippedLinked = 0
        for await event in DuplicateFileScanner.scan(
            root: root,
            protectedPaths: protectedPaths,
            threshold: threshold,
            trashDirectory: trashDirectory
        ) {
            switch event {
            case .progress:
                progressEvents += 1
            case .hashing:
                hashingEvents += 1
            case .found(let group):
                groups.append(group)
            case .finished(let unreadableDirectories, let skippedLinkedFiles):
                unreadable = unreadableDirectories
                skippedLinked = skippedLinkedFiles
            }
        }
        return (groups, progressEvents, hashingEvents, unreadable, skippedLinked)
    }

    @Test func groupsOnlyOnFullContentAgreement() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let (groups, progressEvents, hashingEvents, unreadable, skippedLinked) = await scan(
            root: base.path, threshold: threshold)

        #expect(progressEvents > 0, "walk progress precedes the finished scan")
        #expect(hashingEvents > 0, "the comparison stage publishes its byte progress")
        #expect(unreadable == 0)
        #expect(skippedLinked == 2, "both names of the hard-linked pair are skipped")

        // Exactly one group: every payload-P copy at or above the threshold.
        // protected/k.bin belongs here because this scan passes no
        // protectedPaths — protection is opt-in per scan (the dedicated test
        // below passes it). The same-size payload-Q file and the shared-head
        // pair are candidates the full digest rejected — the head digest
        // alone never groups anything.
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        let names = group.files.map(\.name).sorted()
        #expect(names == ["a.bin", "b.bin", "c.bin", "k.bin"])
        #expect(group.files.allSatisfy { $0.size >= threshold })
        #expect(group.wasted == group.files[0].size * 3, "three redundant copies of four files")

        // Nothing else leaked through: no sub-threshold copies, no hard
        // links, no bundle contents, no symlink target alias.
        let listed = Set(groups.flatMap { $0.files.map(\.name) })
        #expect(listed == ["a.bin", "b.bin", "c.bin", "k.bin"])
    }

    @Test func thresholdFiltersCandidatesOut() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        // A threshold above every fixture file finds nothing at all — the
        // identical-content copies included: the threshold is applied while
        // walking, before any comparison happens.
        let (groups, _, _, _, _) = await scan(root: base.path, threshold: 1_000_000)
        #expect(groups.isEmpty)
    }

    @Test func bundleDirectoriesAreNeverEntered() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        // Already covered by the group test's exclusion list; pinned here
        // with the bundle file promoted to a would-be duplicate: it shares
        // the payload, so entering the bundle would have grouped it. The
        // document package is the same rule for a user document on disk.
        let (groups, _, _, _, _) = await scan(root: base.path, threshold: threshold)
        let listed = groups.flatMap { $0.files.map(\.path) }
        #expect(listed.contains { $0.contains("Tool.app") } == false)
        #expect(listed.contains { $0.contains("Report.pages") } == false)
        #expect(listed.contains { $0.contains("/.git/") } == false)
    }

    @Test func copiesWithDifferentAllocationsStillGroup() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-duplicate-sparse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // The same logical bytes, allocated differently: one full copy and
        // one sparse file whose holes read back as zeros. Bucketing by
        // allocation would put them in different first-pass buckets and miss
        // the duplicate entirely; the walk keys on logical size instead.
        try write(Data(repeating: 0, count: payloadSize), at: base.appendingPathComponent("dense.bin"))
        try writeSparse(size: payloadSize, at: base.appendingPathComponent("sparse.bin"))

        let (groups, _, _, _, _) = await scan(root: base.path, threshold: threshold)

        #expect(groups.count == 1, "sparse and dense copies of the same bytes are duplicates")
        let group = try #require(groups.first)
        #expect(group.files.map(\.name).sorted() == ["dense.bin", "sparse.bin"])
        #expect(group.files.map(\.size).min() == 0, "the sparse copy allocates no blocks")
    }

    @Test func protectedPathsAreSkippedWhole() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let protected = base.appendingPathComponent("protected").path
        let (groups, _, _, _, _) = await scan(
            root: base.path, threshold: threshold, protectedPaths: [protected])
        let listed = groups.flatMap { $0.files.map(\.name) }
        #expect(listed.contains("k.bin") == false)
        #expect(groups.count == 1, "the rest of the fixture is unaffected")
    }

    /// keep/{a,b}.bin plus .Trash/{t1,t2}.bin, all carrying the same
    /// payload — a four-way would-be group split across the Trash boundary.
    private func makeTrashFixture() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-duplicate-trash-\(UUID().uuidString)", isDirectory: true)
        let p = payload(0xAA, size: payloadSize)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try write(p, at: base.appendingPathComponent("keep/a.bin"))
        try write(p, at: base.appendingPathComponent("keep/b.bin"))
        try write(p, at: base.appendingPathComponent(".Trash/t1.bin"))
        try write(p, at: base.appendingPathComponent(".Trash/t2.bin"))
        return base
    }

    @Test func trashDirectoryIsNeverEntered() async throws {
        let base = try makeTrashFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        // The Trash's contents are already marked for removal, and the clean
        // engine deletes in-Trash items outright, so a copy sitting there
        // must never join a group — the sheet would say "moved to Trash"
        // over a permanent delete. The fixture's own Trash is passed in,
        // because the walk resolves the real system Trash from the root's
        // volume and a temp fixture cannot be it.
        let (groups, _, _, _, _) = await scan(
            root: base.path,
            threshold: threshold,
            trashDirectory: base.appendingPathComponent(".Trash")
        )

        #expect(groups.count == 1, "the copies outside the Trash still group")
        let group = try #require(groups.first)
        #expect(group.files.map(\.name).sorted() == ["a.bin", "b.bin"])
    }

    @Test func aFolderMerelyNamedTrashIsOrdinaryContent() async throws {
        let base = try makeTrashFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        // The control: without the injection the walk resolves the *real*
        // Trash from the fixture's volume — a folder under /var/folders can
        // never be it — so a folder that merely carries the name is ordinary
        // content and its copies join the group. The exclusion is exact
        // identity with the system Trash, not a name match.
        let (groups, _, _, _, _) = await scan(root: base.path, threshold: threshold)

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.files.map(\.name).sorted() == ["a.bin", "b.bin", "t1.bin", "t2.bin"])
    }

    @Test func filesCarryIdentityAndModificationDate() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp],
            ofItemAtPath: base.appendingPathComponent("alpha/a.bin").path
        )

        let (groups, _, _, _, _) = await scan(root: base.path, threshold: threshold)
        let group = try #require(groups.first)
        let a = try #require(group.files.first { $0.name == "a.bin" })
        #expect(a.nodeIdentity != nil, "the identity the clean engine re-checks travels with the file")
        guard let modified = a.modified else {
            Issue.record("the stamped file lost its date")
            return
        }
        #expect(abs(modified.timeIntervalSince1970 - stamp.timeIntervalSince1970) < 2)
    }
}
