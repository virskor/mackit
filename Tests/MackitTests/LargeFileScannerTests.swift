import Foundation
import Testing

@testable import Mackit

/// The large-file scanner walks one directory tree and reports every regular
/// file at or above a size threshold. The fixture pins down the behaviors the
/// page depends on: the threshold filter (inclusive), allocated sizes and
/// modification dates, the skip rules — symlinked children, `com.apple.*`
/// system data (which would pop a TCC authorization dialog on macOS 26+),
/// mount points, and the protected-path set — and the unreadable-directory
/// count the finished event carries.
@Suite(.serialized)
struct LargeFileScannerTests {
    /// The threshold the fixture is built around. Small on purpose: the
    /// filter's logic does not care about absolute sizes, and a whole-disk
    /// walk's cost is IO this suite should not add to.
    private let threshold = Int64(100_000)

    /// A block-aligned size (32 × 4 KB): the kernel allocates exactly this
    /// many bytes for it, which is what makes the boundary test able to
    /// assert inclusion *at* the threshold rather than above it.
    private let aligned = Int64(131_072)

    private func write(size: Int, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: size).write(to: url)
    }

    /// base/
    ///   big/           120 KB + 120 KB + nested/120 KB → three hits
    ///   small/         1 KB                           → below the threshold
    ///   root.bin       128 KB (block-aligned)         → a hit, with a known date
    ///   protected/     128 KB                        → passed as protectedPaths
    ///   com.apple.Music/                              → skipped (TCC-protected)
    ///   link → big/                                   → skipped (symlink)
    private func makeFixture() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-large-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try write(size: 120_000, at: base.appendingPathComponent("big/a.bin"))
        try write(size: 120_000, at: base.appendingPathComponent("big/b.bin"))
        try write(size: 120_000, at: base.appendingPathComponent("big/nested/c.bin"))
        try write(size: 1_000, at: base.appendingPathComponent("small/d.bin"))
        try write(size: Int(aligned), at: base.appendingPathComponent("root.bin"))
        try write(size: Int(aligned), at: base.appendingPathComponent("protected/hidden.bin"))
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

    /// Runs a walk to completion and returns the hits, the progress-event
    /// count and the unreadable-directory count the finished event carries.
    private func scan(
        root: String,
        threshold: Int64,
        protectedPaths: Set<String> = []
    ) async -> (files: [LargeFile], progressEvents: Int, unreadable: Int) {
        var files: [LargeFile] = []
        var progressEvents = 0
        var unreadable = 0
        for await event in LargeFileScanner.scan(root: root, protectedPaths: protectedPaths, threshold: threshold) {
            switch event {
            case .progress:
                progressEvents += 1
            case .found(let file):
                files.append(file)
            case .finished(let unreadableDirectories):
                unreadable = unreadableDirectories
            }
        }
        return (files, progressEvents, unreadable)
    }

    @Test func walkReportsFilesAtOrAboveThreshold() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let (files, progressEvents, unreadable) = await scan(root: base.path, threshold: threshold)

        #expect(progressEvents > 0, "progress events precede the finished walk")
        #expect(unreadable == 0)
        // The five files at or above the threshold — including the one under
        // protected/, which is only skipped when its path is passed in (see
        // the dedicated test). The 1 KB file, the symlink and the com.apple.*
        // child are absent.
        #expect(files.map(\.name).sorted() == ["a.bin", "b.bin", "c.bin", "hidden.bin", "root.bin"])
        #expect(files.allSatisfy { $0.size >= threshold })

        let root = try #require(files.first { $0.name == "root.bin" })
        #expect(root.path == base.appendingPathComponent("root.bin").path)
        #expect(root.parentPath == base.path)
        #expect(root.modified != nil, "a hit carries the date the staleness readout needs")
    }

    @Test func thresholdIsInclusiveAndFiltersEverythingBelow() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        // A threshold above the fixture's largest file finds nothing.
        let (none, _, _) = await scan(root: base.path, threshold: 1_000_000)
        #expect(none.isEmpty)

        // The boundary itself counts: "1 GB 以上" includes the file that is
        // exactly that size. The two 128 KB files are block-aligned, so the
        // kernel allocates exactly the threshold for them.
        let (files, _, _) = await scan(root: base.path, threshold: aligned)
        #expect(files.map(\.name).sorted() == ["hidden.bin", "root.bin"])
        #expect(files.allSatisfy { $0.size >= aligned })
    }

    @Test func skipsProtectedPathsWithoutEnteringThem() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let protected = base.appendingPathComponent("protected").path
        let (files, _, _) = await scan(
            root: base.path,
            threshold: threshold,
            protectedPaths: [protected]
        )
        // Not listed and not traversed: the folder is skipped whole, the same
        // rule the disk analysis applies to the TCC-protected home trio.
        #expect(files.contains { $0.name == "hidden.bin" } == false)
        #expect(files.map(\.name).sorted() == ["a.bin", "b.bin", "c.bin", "root.bin"])
    }

    @Test func hitCarriesTheFilesModificationDate() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        let stamped = base.appendingPathComponent("root.bin")
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: stamped.path)

        let (files, _, _) = await scan(root: base.path, threshold: threshold)
        let root = try #require(files.first { $0.name == "root.bin" })
        guard let modified = root.modified else {
            Issue.record("the stamped file lost its date")
            return
        }
        #expect(abs(modified.timeIntervalSince1970 - stamp.timeIntervalSince1970) < 2)
    }

    @Test func unreadableDirectoriesAreCounted() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let locked = base.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try write(size: Int(aligned), at: locked.appendingPathComponent("huge.bin"))
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        // A process running as root reads every directory, so the count can
        // only be asserted where the lock actually bites.
        guard FileSystem.entries(of: locked.path) == nil else { return }

        let (files, _, unreadable) = await scan(root: base.path, threshold: threshold)
        #expect(unreadable == 1, "the unreadable folder is counted, not silently skipped")
        #expect(files.contains { $0.name == "huge.bin" } == false)
    }
}
