import Foundation
import Testing

@testable import Mackit

struct RulesCatalogTests {
    @Test func ruleIDsAreUnique() {
        let ids = RulesCatalog.scanRules.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func cliRuleIDsAreUnique() {
        let ids = RulesCatalog.cliRules.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyRuleHasTitleAndNote() {
        for rule in RulesCatalog.scanRules {
            #expect(!rule.title.isEmpty, "\(rule.id) is missing a title")
            #expect(!rule.note.isEmpty, "\(rule.id) is missing a note")
        }
        for rule in RulesCatalog.cliRules {
            #expect(!rule.title.isEmpty, "\(rule.id) is missing a title")
            #expect(!rule.note.isEmpty, "\(rule.id) is missing a note")
            #expect(!rule.arguments.isEmpty, "\(rule.id) is missing arguments")
        }
    }

    @Test func everyCategoryExceptProjectsHasStaticRules() {
        // .projects is produced dynamically by the custom project directory scan,
        // and .apps is produced dynamically by the app uninstall tool's scan;
        // neither goes through the static rule table. .language (useless .lproj
        // inside app bundles) and .downloads (installers in ~/Downloads) are
        // produced by their own scanners, whose matching logic can't be
        // expressed as static targets. .appJunk rides along with the app junk
        // scan: its entries are the same ~/Library paths the residue probe
        // already walks, only filed under the general module instead of the
        // uninstall tool.
        let staticCategories = Set(RulesCatalog.scanRules.map(\.category))
            .union(RulesCatalog.cliRules.map(\.category))
        for category in JunkCategory.allCases
        where category != .projects && category != .apps && category != .language
            && category != .downloads && category != .appJunk {
            #expect(staticCategories.contains(category), "\(category.rawValue) has no rules")
        }
    }

    @Test func everyCLIRuleCategoryHasPathRulesToo() {
        // CLI rules should coexist with path rules of the same category, to avoid the same tool being scattered across two categories
        let pathCategories = Set(RulesCatalog.scanRules.map(\.category))
        for rule in RulesCatalog.cliRules {
            #expect(
                pathCategories.contains(rule.category),
                "\(rule.id)'s category \(rule.category.rawValue) has no matching path rule"
            )
        }
    }

    @Test func projectJunkScanFindsBuildArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-project-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let junkDirs = ["node_modules", "build", ".dart_tool", "Pods", "target"]
        let keepDirs = ["src", "lib"]
        for name in junkDirs + keepDirs {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try "code".write(
            to: root.appendingPathComponent("src/main.swift"),
            atomically: true,
            encoding: .utf8
        )

        let found = ScanEngine.scanProjectJunk(
            root: root.path,
            names: ProjectJunkNames.defaults,
            maxDepth: 6
        )

        let names = Set(found.map(\.title))
        for expected in junkDirs {
            #expect(names.contains(expected), "not found \(expected)")
        }
        for unexpected in keepDirs {
            #expect(!names.contains(unexpected), "false positive \(unexpected)")
        }
        #expect(found.allSatisfy { $0.category == .projects })
        // target is an artifact that must be re-downloaded/rebuilt, so its risk should be higher than a pure cache
        #expect(found.first { $0.title == "target" }?.risk == .review)
        #expect(found.first { $0.title == "node_modules" }?.risk == .safe)
    }

    @Test func projectJunkScanDoesNotDescendIntoFoundJunk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-nested-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The inside of node_modules should not be recursively scanned to find a second node_modules
        let outer = root.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outer.appendingPathComponent("pkg/node_modules", isDirectory: true),
            withIntermediateDirectories: true
        )

        let found = ScanEngine.scanProjectJunk(
            root: root.path,
            names: ProjectJunkNames.defaults,
            maxDepth: 8
        )
        #expect(found.count == 1)
        #expect(found.first?.title == "node_modules")
    }

    @Test func projectJunkScanReturnsEmptyForMissingRoot() {
        let found = ScanEngine.scanProjectJunk(
            root: "/definitely/not/a/real/path",
            names: ProjectJunkNames.defaults,
            maxDepth: 6
        )
        #expect(found.isEmpty)
    }

    /// A project root that is itself a symlink must still be scanned. The bulk
    /// listing opens directories with O_DIRECTORY, which refuses to follow a
    /// link (ENOTDIR, verified), and the `try?` around it turned that into a
    /// silent empty result: the user points Mackit at a project kept on another
    /// volume and linked back, and the scan reports no junk at all.
    @Test func projectJunkScanFollowsASymlinkedRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-symroot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("node_modules", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("link"),
            withDestinationURL: real
        )

        let found = ScanEngine.scanProjectJunk(
            root: base.appendingPathComponent("link").path,
            names: ProjectJunkNames.defaults,
            maxDepth: 4
        )

        #expect(found.count == 1, "a symlinked root produced \(found.count) entries: \(found.map(\.path))")
        #expect(found.first?.title == "node_modules")
        // The reported path is the real one — the same directory either
        // spelling addresses, and the one the bytes actually live in.
        #expect(found.first?.path == FileSystem.canonical(real.appendingPathComponent("node_modules").path))
    }

    /// A self-referential symlink inside a project must not be walked once per
    /// depth level: a symlinked directory is not the project's own directory,
    /// and a loop otherwise gets a fresh path spelling at every level, so a
    /// path-keyed dedup cannot recognize it and the same subtree is measured
    /// (and reported) repeatedly.
    ///
    /// The local filesystems make `contentsOfDirectory` refuse to open a
    /// symlink, so this pins the intent rather than guarding a live hole — the
    /// exclusion is now explicit in the walk instead of incidental.
    @Test func projectJunkScanDoesNotFollowSymlinkLoops() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("node_modules", isDirectory: true),
            withIntermediateDirectories: true
        )
        // The loop: the project contains a link back to itself.
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("loop"),
            withDestinationURL: project
        )

        let found = ScanEngine.scanProjectJunk(
            root: root.path,
            names: ProjectJunkNames.defaults,
            maxDepth: 8
        )

        #expect(found.count == 1, "the loop produced \(found.count) entries: \(found.map(\.path))")
        #expect(found.first?.title == "node_modules")
    }

    /// The same directory reached through two paths is one subtree: a second
    /// link into a directory that is also on the regular path must not have its
    /// contents measured twice, which would double-count the bytes and report
    /// the same target as two separate items. The walk deduplicates by vnode,
    /// so the alias cannot produce a second pass over the same tree.
    @Test func projectJunkScanCountsADirectoryReachedTwiceOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-alias-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(
            at: shared.appendingPathComponent("build", isDirectory: true),
            withIntermediateDirectories: true
        )
        // A second path to the same directory.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias"),
            withDestinationURL: shared
        )

        let found = ScanEngine.scanProjectJunk(
            root: root.path,
            names: ProjectJunkNames.defaults,
            maxDepth: 4
        )

        #expect(found.count == 1, "the aliased directory produced \(found.count) entries: \(found.map(\.path))")
        #expect(found.first?.title == "build")
    }

    @Test func everyRuleTargetResolvesOrIsEmpty() {
        // Paths in rules must expand; returning empty for nonexistent directories is expected
        for rule in RulesCatalog.scanRules {
            switch rule.target {
            case .children(let path), .directory(let path):
                #expect(!FileSystem.expand(path).isEmpty)
            case .glob(let pattern):
                #expect(!FileSystem.expand(pattern).isEmpty)
            }
        }
    }

    @Test func displayNameIsNeverEmpty() {
        for rule in RulesCatalog.scanRules {
            let url = URL(fileURLWithPath: "/tmp/some-entry")
            #expect(!rule.displayName(for: url).isEmpty, "\(rule.id) has an empty display name")
        }
    }

    @Test func projectJunkNamesHaveNoDuplicates() {
        #expect(Set(ProjectJunkNames.defaults).count == ProjectJunkNames.defaults.count)
    }

    @Test func cliCommandsAreSafe() {
        // CLI cleaning should not include destructive commands like rm
        let forbidden: Set<String> = ["rm", "rmdir", "mv", "dd", "shred", "kill"]
        for rule in RulesCatalog.cliRules {
            #expect(!forbidden.contains(rule.executable), "\(rule.id) uses a dangerous command")
        }
    }
}
