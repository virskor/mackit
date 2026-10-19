import SwiftUI

/// A group on the general cleanup page, following Lemon's grouping: system
/// junk first, browsing junk second.
enum GeneralCleanGroup: String, CaseIterable, Identifiable, Sendable {
    case system
    case browser

    var id: String { rawValue }

    var title: String {
        L10n.tr("general.group.\(rawValue)")
    }

    var tint: Color {
        switch self {
        case .system: return .orange
        case .browser: return .blue
        }
    }

    /// The categories this group covers, in row order.
    var categories: [JunkCategory] {
        switch self {
        case .system: return [.system, .language, .downloads, .trash]
        case .browser: return [.browser]
        }
    }
}

/// One rule row on the general cleanup page.
///
/// Several catalog rules can roll up into a single row: Chrome's cache and
/// code cache are one "Chrome" row to the user, and the Downloads installers
/// and archives are one "Downloads" row. Everything is either safe or review
/// here except the explicitly cautious rows (Trash, Downloads, iOS backups),
/// which stay unchecked until the user opts in.
struct GeneralRuleRow: Identifiable, Sendable {
    let id: String
    let title: String
    let note: String
    let category: JunkCategory
    /// Catalog / scanner rule ids whose items roll up into this row.
    let ruleIDs: [String]
    /// The row's risk level; every aggregated rule shares it.
    let risk: RiskLevel
}

/// The row layout of the general cleanup page.
///
/// Static rather than derived from the catalog on purpose: the page is a
/// curated, Lemon-like checklist, and the aggregation (which rules share a
/// row, in which order) is presentation knowledge. `GeneralCleanLayoutTests`
/// asserts the layout stays in sync with the catalog — every general-scoped
/// rule appears in exactly one row, and no row references a missing rule.
enum GeneralCleanLayout {
    /// A 1:1 row: title and note come from the catalog rule itself.
    private static func ruleRow(_ ruleID: String) -> GeneralRuleRow {
        let rule = RulesCatalog.scanRules.first { $0.id == ruleID }!
        return GeneralRuleRow(
            id: ruleID,
            title: rule.title,
            note: rule.note,
            category: rule.category,
            ruleIDs: [ruleID],
            risk: rule.risk
        )
    }

    static let rows: [GeneralRuleRow] = [
        // 系统垃圾
        ruleRow("system.logs"),
        ruleRow("system.crashreporter"),
        ruleRow("system.saved-state"),
        ruleRow("system.autosave"),
        ruleRow("system.itunes-ipsw"),
        GeneralRuleRow(
            id: "language",
            title: L10n.tr("category.language.title"),
            note: L10n.tr("category.language.summary"),
            category: .language,
            ruleIDs: [LanguageFileScanner.ruleID],
            risk: .review
        ),
        GeneralRuleRow(
            id: "downloads",
            title: L10n.tr("general.row.downloads.title"),
            note: L10n.tr("general.row.downloads.note"),
            category: .downloads,
            ruleIDs: [DownloadsScanner.installerRuleID, DownloadsScanner.archiveRuleID],
            risk: .caution
        ),
        ruleRow("system.ios-backups"),
        ruleRow("trash.home"),

        // 上网垃圾
        GeneralRuleRow(
            id: "browser.chrome",
            title: L10n.tr("rule.browser.chrome-cache.title"),
            note: L10n.tr("rule.browser.chrome-cache.note"),
            category: .browser,
            ruleIDs: ["browser.chrome-cache", "browser.chrome-code-cache"],
            risk: .safe
        ),
        GeneralRuleRow(
            id: "browser.edge",
            title: L10n.tr("rule.browser.edge-cache.title"),
            note: L10n.tr("rule.browser.edge-cache.note"),
            category: .browser,
            ruleIDs: ["browser.edge-cache", "browser.edge-code-cache"],
            risk: .safe
        ),
        ruleRow("browser.chromium-cache"),
        ruleRow("browser.brave-cache"),
        ruleRow("browser.arc-cache"),
        ruleRow("browser.opera-cache"),
        ruleRow("browser.firefox-cache"),
        ruleRow("browser.qqbrowser-cache"),
    ]

    /// The rows of one group, in display order.
    static func rows(of group: GeneralCleanGroup) -> [GeneralRuleRow] {
        rows.filter { group.categories.contains($0.category) }
    }
}
