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

    /// The disk analysis page's summary counts: the entry's *direct* children
    /// split into folders and files — the same numbers the mockup reports
    /// (Users: 2 folders 1 file = its 3 direct children) — while the size
    /// stays recursive, since that is what the treemap areas show. A
    /// symlinked directory is neither followed nor counted: the analysis
    /// listing skips symlinks, so counting one would report an entry the user
    /// never sees.
    @Test func allocatedSizeAndCountsCountsFoldersAndFiles() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-counts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let mb = 1024 * 1024
        try Data(repeating: 0, count: mb).write(to: base.appendingPathComponent("a.bin"))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 0, count: mb).write(to: base.appendingPathComponent("sub/b.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: base.appendingPathComponent("link").path,
            withDestinationPath: base.appendingPathComponent("sub").path
        )

        let counts = FileSystem.allocatedSizeAndCounts(of: base)
        #expect(counts.folders == 1, "only sub/ is a direct folder; the symlink is skipped")
        #expect(counts.files == 1, "only a.bin is a direct file; b.bin sits inside sub/")
        // The size is recursive: it must still cover sub/b.bin.
        #expect(counts.size > 1_900_000)

        // A plain file has no contents to count, only a size.
        let fileCounts = FileSystem.allocatedSizeAndCounts(of: base.appendingPathComponent("a.bin"))
        #expect(fileCounts.files == 0)
        #expect(fileCounts.folders == 0)
        #expect(fileCounts.size > 900_000)

        // A missing path reports nothing rather than crashing.
        let missing = FileSystem.allocatedSizeAndCounts(of: base.appendingPathComponent("nope"))
        #expect(missing.size == 0 && missing.folders == 0 && missing.files == 0)
    }

    /// com.apple.* subtrees are pruned mid-traversal: on macOS 26+ enumerating
    /// them pops a TCC authorization dialog, and the analysis runs full-disk
    /// traversals where the cleaning engine's listing-level filter alone
    /// would not reach.
    @Test func allocatedSizeAndCountsPrunesSystemDataSubtrees() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let mb = 1024 * 1024
        try FileManager.default.createDirectory(at: base.appendingPathComponent("keep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("com.apple.Music"), withIntermediateDirectories: true)
        try Data(repeating: 0, count: mb).write(to: base.appendingPathComponent("keep/a.bin"))
        try Data(repeating: 0, count: 5 * mb).write(to: base.appendingPathComponent("com.apple.Music/huge.bin"))

        let counts = FileSystem.allocatedSizeAndCounts(of: base)
        #expect(counts.folders == 1, "only keep/ is a direct folder")
        #expect(counts.files == 0)
        #expect(counts.size > 900_000, "keep/a.bin is counted")
        #expect(counts.size < 2_000_000, "the pruned com.apple.* payload must not be counted: \(counts.size)")
    }
}
