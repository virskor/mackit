import Foundation
import Testing

@testable import Mackit

/// The general cleanup page's layout must stay in sync with the rule catalog,
/// and the two cleanup features must never target the same path — that
/// double-counting was the overlap the module split set out to remove.
struct GeneralCleanLayoutTests {
    @Test func everyGeneralRuleAppearsInExactlyOneRow() {
        // Dynamic (non-catalog) rule ids the layout knows about
        let dynamicIDs: Set<String> = [
            LanguageFileScanner.ruleID,
            DownloadsScanner.installerRuleID,
            DownloadsScanner.archiveRuleID,
        ]

        let generalRules = RulesCatalog.scanRules.filter { $0.category.scope == .general }
        #expect(!generalRules.isEmpty, "常规清理没有任何规则")

        for rule in generalRules {
            let rows = GeneralCleanLayout.rows.filter { $0.ruleIDs.contains(rule.id) }
            #expect(rows.count == 1, "\(rule.id) 出现在 \(rows.count) 个行里")
            #expect(rows.first?.category == rule.category, "\(rule.id) 的分类与行不一致")
            #expect(rows.first?.risk == rule.risk, "\(rule.id) 的风险等级与行不一致")
        }
        for id in dynamicIDs {
            #expect(GeneralCleanLayout.rows.contains { $0.ruleIDs.contains(id) }, "\(id) 没有任何行")
        }
    }

    @Test func noRowReferencesAMissingRule() {
        let catalogIDs = Set(RulesCatalog.scanRules.map(\.id))
        let dynamicIDs: Set<String> = [
            LanguageFileScanner.ruleID,
            DownloadsScanner.installerRuleID,
            DownloadsScanner.archiveRuleID,
        ]
        for row in GeneralCleanLayout.rows {
            for id in row.ruleIDs {
                #expect(catalogIDs.contains(id) || dynamicIDs.contains(id), "行 \(row.id) 引用了不存在的规则 \(id)")
            }
        }
    }

    @Test func layoutOnlyCoversGeneralCategories() {
        for row in GeneralCleanLayout.rows {
            #expect(row.category.scope == .general, "行 \(row.id) 属于开发者分类 \(row.category.rawValue)")
        }
        // Both groups have rows
        for group in GeneralCleanGroup.allCases {
            #expect(!GeneralCleanLayout.rows(of: group).isEmpty, "分组 \(group.rawValue) 没有任何行")
        }
    }

    @Test func cautiousRowsAreExactlyTheOnesThatNeedConfirmation() {
        // Trash, Downloads and iOS backups hold user content: they must stay
        // unchecked until the user opts in.
        let cautious = Set(GeneralCleanLayout.rows.filter { $0.risk == .caution }.map(\.id))
        #expect(cautious == ["downloads", "system.ios-backups", "trash.home"])
    }

    /// The catch-all rules that made browser and IDE caches count twice are
    /// gone: nothing may enumerate all of ~/Library/Caches or
    /// ~/Library/Containers wholesale anymore.
    @Test func noCatchAllRulesRemain() {
        let ids = Set(RulesCatalog.scanRules.map(\.id))
        #expect(!ids.contains("system.user-caches"))
        #expect(!ids.contains("system.container-caches"))
        #expect(!ids.contains("system.diagnostic"))
    }

    /// No rule's target may contain another rule's target: a path cleaned by
    /// two rules would be counted (and shown) twice. Directory and glob
    /// targets are compared by literal prefix; globs only ever point at cache
    /// leaves, which the prefix check covers for the shapes in this catalog.
    @Test func noRuleTargetContainsAnother() {
        let targets = RulesCatalog.scanRules.map { rule -> (id: String, path: String) in
            switch rule.target {
            case .children(let path), .directory(let path), .glob(let path):
                return (rule.id, path)
            }
        }
        for (id, path) in targets {
            for (otherID, otherPath) in targets where otherID != id {
                let contains = path.hasPrefix(otherPath + "/") || path == otherPath
                #expect(!contains, "\(id) 的目标 \(path) 包含了 \(otherID) 的目标 \(otherPath)")
            }
        }
    }
}
