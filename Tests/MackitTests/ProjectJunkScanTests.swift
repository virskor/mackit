import Foundation
import Testing

@testable import Mackit

/// Tests for the project-root artifact walk.
///
/// The walk enumerates with `FileSystem.entries(of:)` — one
/// `getattrlistbulk` per directory instead of a stat per entry — so these
/// also pin what the bulk record decides: entry types are read from the
/// directory listing itself (a symlinked artifact directory is a link, not a
/// directory), and `com.apple.*` entries stay skipped.
struct ProjectJunkScanTests {
    private let names = ["node_modules", "build", "dist"]

    /// The fixture root, created for real: a swallowed error here would
    /// turn every empty-result assertion below into a vacuous pass.
    private func tempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-projscan-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The walk canonicalizes its root (realpath), so the expected paths
        // have to be spelled the resolved way (/var → /private/var) or the
        // comparison silently fails on the symlink spelling.
        return URL(fileURLWithPath: FileSystem.canonical(url.path))
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeDirectory(_ path: String, under root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(path),
            withIntermediateDirectories: true
        )
    }

    @Test func findsArtifactDirectoriesAndReportsRelativePaths() throws {
        let root = try tempDirectory("basic")
        defer { cleanup(root) }
        try makeDirectory("web/node_modules", under: root)
        try makeDirectory("web/build", under: root)
        try makeDirectory("api/dist", under: root)

        let found = ScanEngine.scanProjectJunk(root: root.path, names: names, maxDepth: 8)

        #expect(found.count == 3)
        #expect(found.contains { $0.path == root.appendingPathComponent("web/node_modules").path })
        #expect(found.contains { $0.path == root.appendingPathComponent("api/dist").path })
        // The detail is the path relative to the root, so the row says where
        // the artifact sits inside the project rather than repeating the root.
        let dist = try #require(found.first { $0.title == "dist" })
        #expect(dist.detail.contains("api/dist"))
        #expect(!dist.detail.contains(root.path))
        #expect(dist.category == .projects)
        #expect(dist.isDirectory)
    }

    /// `node_modules` can hold tens of thousands of directories, so the walk
    /// stops descending once it has claimed one: an artifact inside an
    /// artifact is not a second item.
    @Test func doesNotDescendIntoAnArtifact() throws {
        let root = try tempDirectory("nested")
        defer { cleanup(root) }
        try makeDirectory("web/node_modules/left-pad/build", under: root)

        let found = ScanEngine.scanProjectJunk(root: root.path, names: names, maxDepth: 8)

        #expect(found.count == 1)
        #expect(found.first?.path == root.appendingPathComponent("web/node_modules").path)
    }

    /// Hidden directories are the user's own (`.git`, `.cache`); the walk
    /// skips them rather than surfacing their contents as project junk.
    @Test func skipsHiddenDirectories() throws {
        let root = try tempDirectory("hidden")
        defer { cleanup(root) }
        try makeDirectory(".git/node_modules", under: root)

        let found = ScanEngine.scanProjectJunk(root: root.path, names: names, maxDepth: 8)

        #expect(found.isEmpty)
    }

    @Test func respectsMaxDepth() throws {
        let root = try tempDirectory("depth")
        defer { cleanup(root) }
        try makeDirectory("a/b/c/node_modules", under: root)

        // The depth in the walk is that of the directory being listed: the
        // root is 0, so the artifact four levels down needs a maxDepth past
        // its parent's own depth.
        #expect(ScanEngine.scanProjectJunk(root: root.path, names: names, maxDepth: 3).isEmpty)
        #expect(ScanEngine.scanProjectJunk(root: root.path, names: names, maxDepth: 4).count == 1)
    }

    /// A symlinked artifact directory is a deliberate link, not an artifact
    /// tree of its own: the bulk record reports the entry's own type (VLNK),
    /// so it is neither claimed nor descended into.
    @Test func symlinkedArtifactIsNotClaimed() throws {
        let root = try tempDirectory("symlink")
        defer { cleanup(root) }
        let target = try tempDirectory("symlink-target")
        defer { cleanup(target) }
        try makeDirectory("real/node_modules", under: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: target.appendingPathComponent("real")
        )

        let found = ScanEngine.scanProjectJunk(root: root.path, names: names, maxDepth: 8)

        #expect(found.isEmpty)
    }

    /// A root that is itself a symlink is resolved first, so the artifacts
    /// are reported under the real directory the bytes live in.
    @Test func symlinkedRootIsResolved() throws {
        let real = try tempDirectory("real-root")
        defer { cleanup(real) }
        try makeDirectory("web/node_modules", under: real)
        let link = try tempDirectory("link-root")
        defer { cleanup(link) }
        try FileManager.default.createSymbolicLink(
            at: link.appendingPathComponent("project"),
            withDestinationURL: real
        )

        let found = ScanEngine.scanProjectJunk(
            root: link.appendingPathComponent("project").path,
            names: names,
            maxDepth: 8
        )

        #expect(found.count == 1)
        #expect(found.first?.path == real.appendingPathComponent("web/node_modules").path)
    }

    @Test func nonexistentRootYieldsNothing() {
        let found = ScanEngine.scanProjectJunk(
            root: "/definitely/not/a/real/path",
            names: names,
            maxDepth: 8
        )
        #expect(found.isEmpty)
    }
}
