import SwiftUI

/// A group on the general cleanup page, following Lemon's grouping: system
/// junk, app junk, and browsing junk, each a top-level section of the same
/// weight — a user who only wants their apps' caches should not have to find
/// them buried inside the system group.
enum GeneralCleanGroup: String, CaseIterable, Identifiable, Sendable {
    case system
    case appJunk
    case browser

    var id: String { rawValue }

    var title: String {
        L10n.tr("general.group.\(rawValue)")
    }

    var tint: Color {
        switch self {
        case .system: return .orange
        case .appJunk: return .purple
        case .browser: return .blue
        }
    }

    var symbol: String {
        switch self {
        case .system: return "internaldrive"
        case .appJunk: return "square.stack.3d.up.fill"
        case .browser: return "globe"
        }
    }

    /// The categories this group covers, in row order.
    var categories: [JunkCategory] {
        switch self {
        case .system: return [.system, .language, .downloads, .trash]
        case .appJunk: return [.appJunk]
        case .browser: return [.browser]
        }
    }
}

/// One rule row on the general cleanup page.
///
/// Several catalog rules can roll up into a single row: Chrome's cache and
/// code cache are one "Chrome" row to the user, and the Downloads installers
/// and archives are one "Downloads" row. Rows are pre-checked by their safety
/// level — safe and review — except the explicitly cautious ones (Trash,
/// Downloads, iOS backups, autosaved drafts), which stay unchecked until the
/// user opts in, and the unused language packs, which are review-level but
/// opt-in for the reason `preChecked` records.
struct GeneralRuleRow: Identifiable, Sendable {
    let id: String
    let title: String
    let note: String
    let category: JunkCategory
    /// Catalog / scanner rule ids whose items roll up into this row.
    let ruleIDs: [String]
    /// The row's risk level; every aggregated rule shares it.
    let risk: RiskLevel
    /// How the row's entries are grouped into sub-rows; `.flat` for a row
    /// that is a single toggle over all of its entries.
    var subRowMode: GeneralSubRowMode = .flat
    /// Whether a fresh scan pre-checks this row.
    ///
    /// Defaults to the safety level's usual answer — safe and review rows
    /// arrive checked, caution rows never do — and exists so a row can be
    /// deliberately opt-in without being relabelled as dangerous. The unused
    /// language packs are the one such row: deleting them is not destructive,
    /// but it changes the interface language of every installed app at once
    /// and only the user knows whether that is what they wanted, so it has to
    /// be their own click rather than part of "clean everything".
    let preChecked: Bool

    init(
        id: String,
        title: String,
        note: String,
        category: JunkCategory,
        ruleIDs: [String],
        risk: RiskLevel,
        subRowMode: GeneralSubRowMode = .flat,
        preChecked: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.category = category
        self.ruleIDs = ruleIDs
        self.risk = risk
        self.subRowMode = subRowMode
        self.preChecked = preChecked ?? (risk <= .review)
    }
}

/// How a row presents its entries below the row header.
///
/// Lemon shows language files one language at a time ("Japanese — 3 apps,
/// 1.2 MB") instead of one undifferentiated total, and app junk per app. A
/// flat row is one all-or-nothing toggle; a grouped row lets the user keep
/// one language, or one app's caches, while sweeping the rest — which is also
/// the difference between "clean my junk" and "clean my junk except the app I
/// actually use".
enum GeneralSubRowMode: Sendable {
    case flat
    /// One sub-row per language code, titled with the language's own name.
    case byLanguage
    /// One sub-row per owning app, titled with the app's display name.
    case byApp
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
    ///
    /// Optional because the id is a literal and the catalog is the source of
    /// truth: a row whose rule was renamed or removed must drop out of the
    /// page rather than trap the first time the general page renders. The
    /// layout test keeps every id in sync with the catalog, so a nil here is a
    /// developer error the test catches — never a crash in the field.
    private static func ruleRow(_ ruleID: String) -> GeneralRuleRow? {
        guard let rule = RulesCatalog.scanRules.first(where: { $0.id == ruleID }) else { return nil }
        return GeneralRuleRow(
            id: ruleID,
            title: rule.title,
            note: rule.note,
            category: rule.category,
            ruleIDs: [ruleID],
            risk: rule.risk
        )
    }

    // Optional elements are dropped, so a row whose rule id no longer exists
    // in the catalog simply disappears from the page (see `ruleRow`).
    static let rows: [GeneralRuleRow] = [
        // system junk
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
            risk: .review,
            subRowMode: .byLanguage,
            // Opt-in: see `preChecked`. Cleaning these changes the interface
            // language of every app that ships them, so the page must not
            // sweep them as part of a general "clean everything".
            preChecked: false
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

        // app junk
        GeneralRuleRow(
            id: "app.junk",
            title: L10n.tr("category.appJunk.title"),
            note: L10n.tr("category.appJunk.summary"),
            category: .appJunk,
            ruleIDs: [AppScanner.junkRuleID],
            risk: .safe,
            subRowMode: .byApp
        ),

        // browsing junk
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
        GeneralRuleRow(
            id: "browser.chromium",
            title: L10n.tr("rule.browser.chromium-cache.title"),
            note: L10n.tr("rule.browser.chromium-cache.note"),
            category: .browser,
            ruleIDs: ["browser.chromium-cache", "browser.chromium-code-cache"],
            risk: .safe
        ),
        GeneralRuleRow(
            id: "browser.brave",
            title: L10n.tr("rule.browser.brave-cache.title"),
            note: L10n.tr("rule.browser.brave-cache.note"),
            category: .browser,
            ruleIDs: ["browser.brave-cache", "browser.brave-code-cache"],
            risk: .safe
        ),
        GeneralRuleRow(
            id: "browser.arc",
            title: L10n.tr("rule.browser.arc-cache.title"),
            note: L10n.tr("rule.browser.arc-cache.note"),
            category: .browser,
            ruleIDs: ["browser.arc-cache", "browser.arc-code-cache"],
            risk: .safe
        ),
        GeneralRuleRow(
            id: "browser.opera",
            title: L10n.tr("rule.browser.opera-cache.title"),
            note: L10n.tr("rule.browser.opera-cache.note"),
            category: .browser,
            ruleIDs: ["browser.opera-cache", "browser.opera-code-cache"],
            risk: .safe
        ),
        GeneralRuleRow(
            id: "browser.qqbrowser",
            title: L10n.tr("rule.browser.qqbrowser-cache.title"),
            note: L10n.tr("rule.browser.qqbrowser-cache.note"),
            category: .browser,
            ruleIDs: ["browser.qqbrowser-cache", "browser.qqbrowser-code-cache"],
            risk: .safe
        ),
        ruleRow("browser.firefox-cache"),
    ].compactMap { $0 }

    /// The rows of one group, in display order.
    static func rows(of group: GeneralCleanGroup) -> [GeneralRuleRow] {
        rows.filter { group.categories.contains($0.category) }
    }

    /// The row a catalog / scanner rule id rolls up into, nil when no row
    /// claims it (the layout test keeps the catalog and the rows in sync).
    static func rowID(forRuleID ruleID: String) -> String? {
        rows.first { $0.ruleIDs.contains(ruleID) }?.id
    }
}
