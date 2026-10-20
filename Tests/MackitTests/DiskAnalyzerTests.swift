import Foundation
import Testing

@testable import Mackit

/// The disk analyzer measures one directory's children and streams them. The
/// fixture pins down the two behaviors the UI depends on: correct recursive
/// counts/sizes, and skipping symlinked and com.apple.* children (the latter
/// would otherwise pop a TCC authorization dialog on macOS 26+).
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

    @Test func childrenStreamsEveryEntryOnce() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        var listed: [DiskEntry] = []
        var finished = false
        var entries: [DiskEntry] = []
        for await event in DiskAnalyzer.children(of: base.path) {
            switch event {
            case .listed(let pending):
                listed = pending
            case .measured(let entry):
                entries.append(entry)
            case .finished:
                finished = true
            }
        }

        #expect(listed.count == 3, "symlink and com.apple.* children must not be listed: \(String(describing: listed.count))")
        #expect(listed.allSatisfy { !$0.isMeasured }, "listed entries are pending placeholders")
        #expect(finished)
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.isMeasured })
        #expect(Set(entries.map(\.name)) == ["big", "small", "root.bin"])
    }

    @Test func measuresRecursiveSizesAndCounts() async throws {
        let base = try makeFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        var entries: [String: DiskEntry] = [:]
        for await event in DiskAnalyzer.children(of: base.path) {
            if case .measured(let entry) = event { entries[entry.name] = entry }
        }

        let big = entries["big"]
        #expect(big?.isDirectory == true)
        #expect(big?.folderCount == 1, "big contains nested/")
        #expect(big?.fileCount == 2, "big contains a.bin and b.bin")
        #expect(big?.itemCount == 3)
        // 3 MB of payload, allowing for filesystem block rounding
        #expect((big?.size ?? 0) > 2_900_000)
        #expect((big?.size ?? 0) < 3_200_000)

        #expect(entries["small"]?.fileCount == 1)
        #expect(entries["small"]?.folderCount == 0)
        #expect((entries["small"]?.size ?? 0) < 100_000)

        let root = entries["root.bin"]
        #expect(root?.isDirectory == false)
        #expect(root?.folderCount == 0)
        #expect(root?.fileCount == 0)
        #expect((root?.size ?? 0) > 1_900_000)
    }

    @Test func missingDirectoryYieldsNoEntries() async {
        var listed: [DiskEntry] = []
        var finished = false
        var count = 0
        for await event in DiskAnalyzer.children(of: "/definitely/not/a/real/path") {
            switch event {
            case .listed(let pending): listed = pending
            case .measured: count += 1
            case .finished: finished = true
            }
        }
        #expect(listed.isEmpty)
        #expect(count == 0)
        #expect(finished)
    }
}
