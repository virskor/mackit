import Foundation
import Testing

@testable import Mackit

struct FileSystemTests {
    @Test func expandTilde() {
        let home = NSHomeDirectory()
        #expect(FileSystem.expand("~") == home)
        #expect(FileSystem.expand("~/Library/Caches") == "\(home)/Library/Caches")
    }

    @Test func globExpandsStarSegments() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-glob-test-\(UUID().uuidString)", isDirectory: true)
        let nested = base.appendingPathComponent("aaa", isDirectory: true)
            .appendingPathComponent("bb", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let pattern = base.path + "/*/bb"
        let matches = FileSystem.expand(pattern: pattern)
        #expect(matches.count == 1)
        #expect(matches.first?.lastPathComponent == "bb")
    }

    @Test func globReturnsEmptyForMissingPath() {
        let pattern = FileManager.default.temporaryDirectory.path
            + "/mackit-does-not-exist-\(UUID().uuidString)/*"
        #expect(FileSystem.expand(pattern: pattern).isEmpty)
    }

    @Test func childrenReturnsNothingForMissingDirectory() {
        #expect(FileSystem.children(of: "/definitely/not/a/real/path").isEmpty)
    }

    @Test func entriesReturnNilForMissingDirectory() {
        #expect(FileSystem.entries(of: "/definitely/not/a/real/path") == nil)
    }

    /// The entry attributes the disk analysis walks on: node type, symlink
    /// flag, and the allocated size the bulk enumeration reads in the same
    /// syscall as the name. A directory reports no size — the kernel has
    /// nothing to say about one — and a symlink is flagged rather than
    /// resolved.
    @Test func entriesReportTypesSizesAndFlags() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-entries-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try Data(repeating: 0, count: 64 * 1024).write(to: base.appendingPathComponent("file.bin"))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: base.appendingPathComponent("link").path,
            withDestinationPath: base.appendingPathComponent("sub").path
        )

        let entries = try #require(FileSystem.entries(of: base.path))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        let file = try #require(byName["file.bin"])
        #expect(!file.isDirectory)
        #expect(!file.isSymbolicLink)
        #expect(file.allocatedSize >= 64 * 1024)

        let sub = try #require(byName["sub"])
        #expect(sub.isDirectory)
        #expect(sub.allocatedSize == 0, "the kernel reports no size for a directory")

        let link = try #require(byName["link"])
        #expect(link.isSymbolicLink)
        #expect(!link.isDirectory)
        #expect(link.allocatedSize == 0, "a symlink is flagged, never resolved")
    }

    /// com.apple.* system data is TCC-protected on macOS 26+: recursive enumeration pops an
    /// "Allow X to access Apple Music's media library" authorization dialog. Enumeration must skip them.
    @Test func childrenSkipsSystemDataEntries() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-systemdata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        for name in ["com.apple.Music", "com.apple.Safari", "go-build", "com.tencent.dieMigration"] {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        let names = FileSystem.children(of: base.path).map { $0.lastPathComponent }.sorted()
        #expect(names == ["com.tencent.dieMigration", "go-build"], "com.apple.* should be skipped, got: \(names)")
    }

    /// A directory wider than one `getattrlistbulk` buffer: the enumeration
    /// has to keep calling until the kernel reports the directory exhausted.
    /// Stopping after the first batch silently drops the tail — the defect
    /// this pins down cost half the files of a wide cache directory.
    @Test func childrenListsEveryEntryOfAWideDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-wide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let count = 3_000
        for index in 0..<count {
            try Data(repeating: 0, count: 8).write(to: base.appendingPathComponent("f\(index).bin"))
        }

        let names = FileSystem.children(of: base.path)
        #expect(names.count == count, "every entry must survive the multi-batch enumeration: \(names.count)")
        #expect(Set(names.map(\.lastPathComponent)).count == count)

        let entries = try #require(FileSystem.entries(of: base.path))
        #expect(entries.count == count)
        #expect(entries.allSatisfy { !$0.isDirectory })
        // 3000 x 8-byte files, each rounding up to a 4 KB block.
        #expect(entries.reduce(0) { $0 + $1.allocatedSize } >= Int64(count) * 4096)
    }

    /// Glob expansion also skips com.apple.*: container cache rules rely on glob
    /// expansion, and without the skip it would recurse into system apps' sandbox containers.
    @Test func expandSkipsSystemDataEntries() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-systemdata-glob-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        for name in ["com.apple.Music", "com.tencent.wechat"] {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent(name).appendingPathComponent("Cache"),
                withIntermediateDirectories: true
            )
        }

        let matches = FileSystem.expand(pattern: base.path + "/*/Cache")
        let names = matches.map { $0.lastPathComponent }.sorted()
        #expect(names == ["Cache"], "com.apple.* containers should not be expanded, got: \(matches.map(\.path))")
        #expect(matches.first?.pathComponents.contains("com.tencent.wechat") == true)
    }

    @Test func allocatedSizeCountsNestedFiles() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-size-test-\(UUID().uuidString)", isDirectory: true)
        let nested = base.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let payload = String(repeating: "x", count: 4096)
        for name in ["a.txt", "nested/b.txt", "nested/c.txt"] {
            try payload.write(
                to: base.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }

        let result = FileSystem.allocatedSizeAndDate(of: base)
        // 3 files of 4KB each; allocated size is at least the logical size
        #expect(result.size >= 3 * 4096)
        #expect(result.date != nil)
    }

    @Test func allocatedSizeIgnoresSymbolicLinks() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-symlink-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // Put a small file in the directory; the symlink points to a large file outside the directory.
        // If traversal followed symlinks, the size would include the external large file.
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-external-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data(repeating: 0x41, count: 8 * 1024 * 1024).write(to: external)

        try "tiny".write(
            to: base.appendingPathComponent("real.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link.bin"),
            withDestinationURL: external
        )

        let result = FileSystem.allocatedSizeAndDate(of: base)
        #expect(result.size < 1024 * 1024, "the symlink was followed, size is abnormal: \(result.size)")
    }

    @Test func protectedPathsAreRejected() {
        #expect(FileSystem.isProtected("/"))
        #expect(FileSystem.isProtected("/System"))
        #expect(FileSystem.isProtected("/usr/bin"))
        #expect(FileSystem.isProtected("/Library/Apple"))
        #expect(FileSystem.isProtected("~/Library/Keychains"))
        #expect(FileSystem.isProtected(NSHomeDirectory()))
    }

    /// The same file spelled via a symlink (/etc → private/etc) must also be rejected:
    /// removeItem deletes the resolved real path, so accepting only one spelling lets the other bypass it.
    @Test func protectedPathsRejectSymlinkSpellings() {
        #expect(FileSystem.isProtected("/etc/hosts"))
        #expect(FileSystem.isProtected("/private/etc/hosts"))
        // /var and /private/var are the two ends of a firmlink; both spellings of subdirectories are blocked
        #expect(FileSystem.isProtected("/var/db/some-daemon-state"))
        #expect(FileSystem.isProtected("/private/var/db/some-daemon-state"))
    }

    @Test func canonicalResolvesSymlinks() {
        // realpath semantics: /var resolves to /private/var, consistent with contentsOfDirectory
        #expect(FileSystem.canonical("/var") == "/private/var")
        #expect(FileSystem.canonical("/private/var") == "/private/var")
        // Nonexistent paths are returned as-is
        let missing = "/definitely/not/a/real/path-\(UUID().uuidString)"
        #expect(FileSystem.canonical(missing) == missing)
    }

    /// A top-level symlink only counts the link itself: removeItem also removes
    /// only the link when deleting, so counting the size by the target directory over-reports.
    @Test func allocatedSizeOfSymbolicLinkCountsLinkItself() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-toplevel-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: 4 * 1024 * 1024).write(to: target.appendingPathComponent("big.bin"))

        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(FileSystem.allocatedSize(of: link) < 1024, "the symlink was counted at the target's size: \(FileSystem.allocatedSize(of: link))")
        #expect(FileSystem.allocatedSize(of: target) >= 4 * 1024 * 1024)
    }

    @Test func safePathsAreAllowed() {
        #expect(!FileSystem.isProtected("~/Library/Caches/go-build"))
        #expect(!FileSystem.isProtected("~/go/pkg/mod"))
        #expect(!FileSystem.isProtected("~/.pub-cache/hosted"))
    }
}
