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
            #expect(!rule.title.isEmpty, "\(rule.id) 缺少标题")
            #expect(!rule.note.isEmpty, "\(rule.id) 缺少说明")
        }
        for rule in RulesCatalog.cliRules {
            #expect(!rule.title.isEmpty, "\(rule.id) 缺少标题")
            #expect(!rule.note.isEmpty, "\(rule.id) 缺少说明")
            #expect(!rule.arguments.isEmpty, "\(rule.id) 缺少参数")
        }
    }

    @Test func everyCategoryExceptProjectsHasStaticRules() {
        // .projects is produced dynamically by the custom project directory scan,
        // and .apps is produced dynamically by the app scan; neither goes through
        // the static rule table
        let staticCategories = Set(RulesCatalog.scanRules.map(\.category))
            .union(RulesCatalog.cliRules.map(\.category))
        for category in JunkCategory.allCases where category != .projects && category != .apps {
            #expect(staticCategories.contains(category), "\(category.rawValue) 没有任何规则")
        }
    }

    @Test func everyCLIRuleCategoryHasPathRulesToo() {
        // CLI rules should coexist with path rules of the same category, to avoid the same tool being scattered across two categories
        let pathCategories = Set(RulesCatalog.scanRules.map(\.category))
        for rule in RulesCatalog.cliRules {
            #expect(
                pathCategories.contains(rule.category),
                "\(rule.id) 的分类 \(rule.category.rawValue) 没有对应的路径规则"
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
            #expect(names.contains(expected), "未找到 \(expected)")
        }
        for unexpected in keepDirs {
            #expect(!names.contains(unexpected), "误报 \(unexpected)")
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
            #expect(!rule.displayName(for: url).isEmpty, "\(rule.id) 展示名为空")
        }
    }

    @Test func projectJunkNamesHaveNoDuplicates() {
        #expect(Set(ProjectJunkNames.defaults).count == ProjectJunkNames.defaults.count)
    }

    @Test func cliCommandsAreSafe() {
        // CLI cleaning should not include destructive commands like rm
        let forbidden: Set<String> = ["rm", "rmdir", "mv", "dd", "shred", "kill"]
        for rule in RulesCatalog.cliRules {
            #expect(!forbidden.contains(rule.executable), "\(rule.id) 使用了危险命令")
        }
    }
}
