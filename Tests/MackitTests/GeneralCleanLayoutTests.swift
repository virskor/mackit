import Foundation
import Testing

@testable import Mackit

/// The general cleanup page's layout must stay in sync with the rule catalog,
/// and the two cleanup features must never target the same path — that
/// double-counting was the overlap the module split set out to remove.
struct GeneralCleanLayoutTests {
    /// Rule ids that come from a dynamic scanner rather than the catalog.
    private static let dynamicIDs: Set<String> = [
        LanguageFileScanner.ruleID,
        DownloadsScanner.installerRuleID,
        DownloadsScanner.archiveRuleID,
        AppScanner.junkRuleID,
    ]

    @Test func everyGeneralRuleAppearsInExactlyOneRow() {
        let generalRules = RulesCatalog.scanRules.filter { $0.category.scope == .general }
        #expect(!generalRules.isEmpty, "general cleanup has no rules")

        for rule in generalRules {
            let rows = GeneralCleanLayout.rows.filter { $0.ruleIDs.contains(rule.id) }
            #expect(rows.count == 1, "\(rule.id) appears in \(rows.count) rows")
            #expect(rows.first?.category == rule.category, "\(rule.id) category does not match the row")
            #expect(rows.first?.risk == rule.risk, "\(rule.id) risk level does not match the row")
        }
        for id in Self.dynamicIDs {
            #expect(GeneralCleanLayout.rows.contains { $0.ruleIDs.contains(id) }, "\(id) has no rows")
        }
    }

    @Test func noRowReferencesAMissingRule() {
        let catalogIDs = Set(RulesCatalog.scanRules.map(\.id))
        for row in GeneralCleanLayout.rows {
            for id in row.ruleIDs {
                #expect(catalogIDs.contains(id) || Self.dynamicIDs.contains(id), "row \(row.id) references a non-existent rule \(id)")
            }
        }
    }

    /// App junk is the general module's own group: every app's regenerable
    /// residue rolls up into it, so a user can sweep caches without
    /// uninstalling anything. It is `.safe`, so it arrives pre-checked like
    /// every other safe row.
    @Test func appJunkIsItsOwnGroupBesideSystemAndBrowsing() {
        let row = GeneralCleanLayout.rows.first { $0.id == "app.junk" }
        #expect(row != nil, "the app junk row is missing")
        #expect(row?.category == .appJunk)
        #expect(row?.category.scope == .general, "app junk belongs to the junk cleanup feature")
        #expect(row?.risk == .safe, "app junk is all regenerable cache, so it should be safe level")
        #expect(row?.ruleIDs == [AppScanner.junkRuleID])
        // Grouped per app, so one app's caches can be kept while the rest goes
        #expect(row?.subRowMode == .byApp)

        // Its own top-level group, the same weight as system and browsing junk
        // — not a row buried inside the system group
        #expect(GeneralCleanGroup.appJunk.categories == [.appJunk])
        #expect(!GeneralCleanGroup.system.categories.contains(.appJunk))
        #expect(GeneralCleanLayout.rows(of: .appJunk).map(\.id) == ["app.junk"])
        #expect(GeneralCleanGroup.allCases.contains(.appJunk))
        // Every group carries at least one row, so no empty section renders
        for group in GeneralCleanGroup.allCases {
            #expect(!GeneralCleanLayout.rows(of: group).isEmpty, "group \(group.rawValue) has no rows")
        }
    }

    /// Language files group per language, so a single language can be kept
    /// while the rest is swept.
    @Test func languageRowGroupsPerLanguage() {
        let row = GeneralCleanLayout.rows.first { $0.id == "language" }
        #expect(row?.subRowMode == .byLanguage)
        // Still inside the system group, alongside the other system rules
        #expect(GeneralCleanGroup.system.categories.contains(.language))
    }

    /// Every other row is a single flat toggle; the grouped ones are exactly
    /// the two whose entries have a natural owner.
    @Test func onlyTheOwnedRowsAreGrouped() {
        let grouped = Set(GeneralCleanLayout.rows.filter { $0.subRowMode != .flat }.map(\.id))
        #expect(grouped == ["language", "app.junk"])
    }

    @Test func layoutOnlyCoversGeneralCategories() {
        for row in GeneralCleanLayout.rows {
            #expect(row.category.scope == .general, "row \(row.id) belongs to the developer category \(row.category.rawValue)")
        }
        // Both groups have rows
        for group in GeneralCleanGroup.allCases {
            #expect(!GeneralCleanLayout.rows(of: group).isEmpty, "group \(group.rawValue) has no rows")
        }
    }

    @Test func cautiousRowsAreExactlyTheOnesThatNeedConfirmation() {
        // Rows holding content the user may still need: Trash contents, iOS
        // backups, Downloads installers, and the autosaved copies of documents
        // that were never written to disk. They stay unchecked until the user
        // opts in, and the sheet asks a second time.
        let cautious = Set(GeneralCleanLayout.rows.filter { $0.risk == .caution }.map(\.id))
        #expect(cautious == ["downloads", "system.ios-backups", "trash.home", "system.autosave"])
    }

    /// Every row is pre-checked by its safety level except the ones that opt
    /// out. Unused language packs are the one such row: removing them is not
    /// destructive, but it changes the interface language of every installed
    /// app at once, so it must be the user's own click.
    @Test func onlyTheLanguageRowOptsOutOfThePreCheck() {
        for row in GeneralCleanLayout.rows {
            if row.id == "language" {
                #expect(!row.preChecked, "unused language files must not be swept by a default clean")
                #expect(row.risk == .review, "…while staying a review-level row, not a dangerous one")
            } else {
                #expect(
                    row.preChecked == (row.risk <= .review),
                    "\(row.id) should follow its safety level"
                )
            }
        }
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
                #expect(!contains, "\(id)'s target \(path) contains \(otherID)'s target \(otherPath)")
            }
        }
    }
}
