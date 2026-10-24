import Foundation
import Testing

@testable import Mackit

/// Regression tests for the localization infrastructure.
///
/// The specific English/Traditional Chinese wording is deliberately not
/// verified here — that is carried by Localizable.xcstrings, and the test
/// process's language follows the launch environment, so three languages
/// cannot be covered in one process. What can and must be verified is: the
/// catalog is actually reachable (lookups do not degrade to keys), all three
/// translations are present, and placeholders are substituted correctly.
struct LocalizationTests {
    /// On a lookup failure Foundation returns the key verbatim; use this to
    /// detect "not found".
    private func isFallback(_ value: String, key: String) -> Bool {
        value == key
    }

    @Test func everyRuleResolvesFromCatalog() {
        for rule in RulesCatalog.scanRules {
            #expect(!isFallback(rule.title, key: "rule.\(rule.id).title"), "\(rule.id) title not localized")
            #expect(!isFallback(rule.note, key: "rule.\(rule.id).note"), "\(rule.id) note not localized")
        }
        for rule in RulesCatalog.cliRules {
            #expect(!isFallback(rule.note, key: "rule.\(rule.id).note"), "\(rule.id) note not localized")
        }
    }

    @Test func everyCategoryAndRiskResolvesFromCatalog() {
        for category in JunkCategory.allCases {
            #expect(!isFallback(category.title, key: "category.\(category.rawValue).title"))
            #expect(!isFallback(category.summary, key: "category.\(category.rawValue).summary"))
        }
        for level in RiskLevel.allCases {
            #expect(!isFallback(level.title, key: "risk.\(level.rawValue).title"))
            #expect(!isFallback(level.hint, key: "risk.\(level.rawValue).hint"))
        }
        for sort in ItemSort.allCases {
            #expect(!isFallback(sort.title, key: "sort.\(sort.rawValue)"))
        }
    }

    @Test func representativeUIKeysResolveFromCatalog() {
        let keys = [
            "common.cancel", "common.done", "common.add", "common.choose", "common.remove",
            "sidebar.allItems", "sidebar.categories", "sidebar.startupDisk", "sidebar.available",
            "sidebar.settings",
            "table.name", "table.size", "table.modified", "table.risk", "table.path",
            "ctx.revealInFinder", "ctx.openInTerminal", "ctx.copyPath", "ctx.moveToTrash",
            "toolbar.rescan", "toolbar.stopScan", "toolbar.sort", "toolbar.safeOnly",
            "share.button", "share.title", "share.intro", "share.message",
            "share.copy", "share.copied", "share.done",
            "toolbar.searchPlaceholder", "clean.button", "clean.confirm.title",
            "clean.confirm.cleanNow", "clean.progress.title", "clean.result.done",
            "scan.progress.title", "scan.progress.title.general", "scan.progress.cancel", "scan.enumerating", "scan.finished",
            "welcome.title", "welcome.start", "menubar.quit", "panel.reclaimable",
            "settings.tab.general", "settings.launchAtLogin", "settings.moveToTrash",
            "settings.autoSelect.none", "settings.autoSelectHint.none",
            "settings.projects.quickAdd", "settings.about.subtitle", "toast.trashed",
            "count.items.one", "count.items.other",
            "scan.apps", "clean.confirm.uninstall", "clean.error.appRunning",
            "apps.version", "apps.confirm.title", "apps.confirm.note",
            "language.item.detail", "downloads.installer.detail", "downloads.archive.detail",
            "general.remember.title", "general.remember.message",
            "general.remember.action", "general.remember.help",
            "general.restoreDefault", "general.restoreDefault.help",
            "general.group.system", "general.group.browser", "general.group.appJunk",
            "toast.generalDefaultsRestored", "toast.generalSelectionRemembered",
            "category.appJunk.title", "category.appJunk.summary",
            "scope.developer.title", "scope.developer.summary",
            "scope.general.title", "scope.general.summary",
            "category.browser.title", "category.browser.summary",
            "category.language.title", "category.downloads.title",
            "scan.languageFiles", "scan.downloads",
            "apps.confirm.leftoverTitle", "apps.confirm.leftoverDetail",
            "apps.confirm.leftoverMore", "apps.confirm.leftoverAction",
            "apps.ctx.uninstallWithResidue", "apps.ctx.residueOnly",
            "settings.includeApps", "settings.includeAppsHint",
            "panel.cpuUsage", "panel.memoryUsage", "panel.temperature",
            "menubar.thermal.nominal", "menubar.thermal.fair",
            "menubar.thermal.serious", "menubar.thermal.critical",
            "panel.release",
            "settings.tab.menubar", "settings.menubar.header",
            "settings.menubar.cpu", "settings.menubar.memory", "settings.menubar.temperature",
            "settings.menubar.logo",
            "settings.menubar.footer",
            "settings.overlay.header", "settings.overlay.show", "settings.overlay.footer",
            "menubar.cpu", "menubar.memory", "menubar.temperature",
            "panel.quitApp", "panel.quitApp.help", "panel.quitApp.warning",
            "toast.memoryReleased", "toast.memoryReleasedNone",
            "toast.memoryReleasedCancelled", "toast.memoryReleaseFailed",
            "format.gigabytes", "format.terabytes",
            "hw.title", "hw.osVersion",
            "hw.disk", "hw.disk.label", "hw.disk.available", "hw.disk.total",
            "hw.disk.analyze",
            "hw.cpu", "hw.cpu.name", "hw.cpu.cores", "hw.cpu.coresLabel", "hw.cpu.coresSplit",
            "hw.gpu", "hw.gpu.model", "hw.gpu.resolution",
            "hw.memory", "hw.memory.label",
            "hw.battery", "hw.battery.level", "hw.battery.cycles", "hw.battery.health",
            "hw.battery.healthValue", "hw.battery.normal", "hw.battery.serviceRecommended",
            "clean.error.trashFailed", "scan.measuring",
            "sidebar.tools", "sidebar.diskAnalysis", "sidebar.diskAnalysis.help",
            "diskAnalysis.title", "diskAnalysis.nav.back", "diskAnalysis.nav.forward",
            "diskAnalysis.visualization", "diskAnalysis.visualization.help",
            "diskAnalysis.header.folders.one", "diskAnalysis.header.folders.other",
            "diskAnalysis.header.files.one", "diskAnalysis.header.files.other",
            "diskAnalysis.header.total", "diskAnalysis.enter.help", "diskAnalysis.select.help",
            "diskAnalysis.scan.title", "diskAnalysis.scan.current",
            "diskAnalysis.scan.count.one", "diskAnalysis.scan.count.other",
            "diskAnalysis.scan.elapsed", "diskAnalysis.scan.remaining",
            "diskAnalysis.start.explain",
            "diskAnalysis.notScanned", "diskAnalysis.truncated",
            "diskAnalysis.truncated.explain", "diskAnalysis.truncated.action",
            "diskAnalysis.unreadable", "diskAnalysis.fdaHint", "diskAnalysis.empty",
            "diskAnalysis.disk",
            "diskAnalysis.skipped", "diskAnalysis.skipped.explain",
            "diskAnalysis.skipped.action", "diskAnalysis.openSettings",
            "diskAnalysis.openSettings.help",
            "diskAnalysis.others.one", "diskAnalysis.others.other",
            "diskAnalysis.others.help", "diskAnalysis.others.enter.help",
            "diskAnalysis.sizeNotMeasured",
            "diskAnalysis.tile.sizeShare", "diskAnalysis.hover.sizeShare",
            "diskAnalysis.tile.accessibility", "diskAnalysis.overflow.accessibility",
            "format.gigabytes.compact", "format.megabytes.compact", "format.kilobytes.compact",
            "format.terabytes.compact", "format.bytes.compact",
        ]
        for key in keys {
            #expect(!isFallback(L10n.tr(key), key: key), "\(key) not localized")
        }
    }

    /// The two cleanup modes announce different subjects while scanning: the
    /// developer module scans toolchain caches, the general module sweeps
    /// junk. They once shared one string, so the junk page claimed it was
    /// scanning caches.
    @Test func scanProgressTitleIsScopedPerMode() {
        let developer = L10n.tr(CleanupScope.developer.scanProgressTitleKey)
        let general = L10n.tr(CleanupScope.general.scanProgressTitleKey)
        #expect(!isFallback(developer, key: CleanupScope.developer.scanProgressTitleKey))
        #expect(!isFallback(general, key: CleanupScope.general.scanProgressTitleKey))
        #expect(developer != general)
    }

    @Test func formatStringsSubstituteArguments() {
        let withSize = L10n.fmt("clean.buttonWithSize", "1.2 GB")
        #expect(withSize.contains("1.2 GB"))
        #expect(!withSize.contains("%@"))

        let shareMessage = L10n.fmt("share.message", "https://www.mingcui.cn")
        #expect(shareMessage.contains("https://www.mingcui.cn"))
        #expect(!shareMessage.contains("%@"))

        let withCount = L10n.fmt("scan.banner.found.other", 3, "4.5 GB")
        #expect(withCount.contains("3"))
        #expect(withCount.contains("4.5 GB"))
        #expect(!withCount.contains("%@"))
        #expect(!withCount.contains("%lld"))

        // Positional parameters (%1$@ / %2$@ / %3$@): residue file row
        // subtitles and the leftover hint use this layout
        let residueDetail = L10n.fmt("apps.residue.detail", "Foo", "Caches")
        #expect(residueDetail.contains("Foo"))
        #expect(residueDetail.contains("Caches"))
        #expect(!residueDetail.contains("%1$@"))
        #expect(!residueDetail.contains("%2$@"))

        let leftover = L10n.fmt("apps.confirm.leftoverDetail", "Google Chrome, Xcode", 12, "3.2 GB")
        #expect(leftover.contains("Google Chrome, Xcode"))
        #expect(leftover.contains("12"))
        #expect(leftover.contains("3.2 GB"))
        #expect(!leftover.contains("%1$@"))
        #expect(!leftover.contains("%2$lld"))
        #expect(!leftover.contains("%3$@"))

        let more = L10n.fmt("apps.confirm.leftoverMore", 5)
        #expect(more.contains("5"))
        #expect(!more.contains("%lld"))

        // The disk analysis page's size/share lines and accessibility labels.
        // The tile line is width-critical: it must keep the unspaced
        // separator the treemap threshold was measured against, while the
        // hover card uses the spaced one.
        let tile = L10n.fmt("diskAnalysis.tile.sizeShare", "206.53GB", "42%")
        #expect(tile.contains("206.53GB"))
        #expect(tile.contains("42%"))
        #expect(!tile.contains("%1$@"))
        #expect(!tile.contains("%2$@"))
        #expect(!tile.contains(" · "), "the tile line must not gain spaces around its separator")

        let hover = L10n.fmt("diskAnalysis.hover.sizeShare", "206.53GB", "42%")
        #expect(hover.contains("206.53GB"))
        #expect(hover.contains("42%"))
        #expect(!hover.contains("%1$@"))
        #expect(!hover.contains("%2$@"))

        let tileLabel = L10n.fmt("diskAnalysis.tile.accessibility", "Library", "206.53GB", "42%")
        #expect(tileLabel.contains("Library"))
        #expect(tileLabel.contains("206.53GB"))
        #expect(tileLabel.contains("42%"))
        #expect(!tileLabel.contains("%1$@"))
        #expect(!tileLabel.contains("%2$@"))
        #expect(!tileLabel.contains("%3$@"))

        let overflowLabel = L10n.fmt("diskAnalysis.overflow.accessibility", "18 other items", "740.35MB")
        #expect(overflowLabel.contains("18 other items"))
        #expect(overflowLabel.contains("740.35MB"))
        #expect(!overflowLabel.contains("%1$@"))
        #expect(!overflowLabel.contains("%2$@"))
    }

    @Test func itemCountHandlesSingularAndPlural() {
        let one = L10n.items(1)
        let many = L10n.items(7)
        #expect(one.contains("1"))
        #expect(many.contains("7"))
        #expect(!one.contains("%lld"))
        #expect(!many.contains("%lld"))
        // Simplified and Traditional Chinese share the same form here while
        // English differs — only that neither degrades to the key is required
        #expect(!isFallback(one, key: "count.items.one"))
        #expect(!isFallback(many, key: "count.items.other"))
    }

    /// After the catalog is compiled there is one .lproj/Localizable.strings
    /// per language; all three must be present and share the same key set —
    /// a missing translation makes whole parts of the UI fall back to the
    /// source language or to keys.
    @Test func allThreeLocalizationsArePresentAndComplete() throws {
        let languages = ["zh-Hans", "en", "zh-Hant"]
        var keySets: [Set<String>] = []

        for language in languages {
            guard let path = Bundle.module.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: "\(language).lproj"
            ) else {
                Issue.record("missing \(language).lproj/Localizable.strings")
                continue
            }
            guard let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
                Issue.record("\(language).lproj/Localizable.strings failed to parse")
                continue
            }
            #expect(dict.count > 300, "\(language) has only \(dict.count) entries")
            keySets.append(Set(dict.keys))
        }

        #expect(keySets.count == 3)
        if keySets.count == 3 {
            #expect(keySets[0] == keySets[1], "the key set of zh-Hans and en differ")
            #expect(keySets[0] == keySets[2], "the key set of zh-Hans and zh-Hant differ")
        }
    }

    /// The placeholder count must match the caller's argument count, otherwise
    /// String(format:) will have extra or missing arguments.
    @Test func placeholderCountsMatchArgumentCounts() throws {
        // Spot-check several keys with placeholders: the number of
        // placeholders in the value must match the number of arguments at the
        // call site
        let expectations: [(key: String, args: Int)] = [
            ("clean.buttonWithSize", 1),
            ("sidebar.available", 1),
            ("sidebar.diskUsed", 1),
            ("sidebar.totalCapacity", 1),
            ("scan.executing", 1),
            ("scan.measuring", 1),
            ("scan.projectRoot", 1),
            ("projects.relativePath", 1),
            ("toast.trashed", 1),
            ("clean.error.cannotRun", 1),
            ("clean.error.exitCode", 1),
            ("clean.confirm.summary.other", 2),
            ("scan.banner.found.other", 2),
            ("toast.reclaimedWithFailures.other", 2),
            ("welcome.projectRoots.other", 1),
            ("count.items.other", 1),
            ("panel.quitApp.help", 1),
            ("apps.version", 1),
            ("apps.residue.detail", 2),
            ("language.item.detail", 1),
            ("apps.residueSummary.other", 1),
            ("apps.confirm.summary.other", 2),
            ("apps.confirm.running.other", 1),
            ("apps.confirm.leftoverDetail", 3),
            ("apps.confirm.leftoverMore", 1),
            ("clean.error.appRunning", 1),
            ("toast.memoryReleased", 1),
            ("toast.memoryReleaseFailed", 1),
            ("format.gigabytes", 1),
            ("format.terabytes", 1),
            ("hw.osVersion", 2),
            ("hw.cpu.cores", 1),
            ("hw.cpu.coresSplit", 3),
            ("hw.battery.healthValue", 2),
            ("diskAnalysis.title", 2),
            ("diskAnalysis.header.folders.other", 1),
            ("diskAnalysis.header.files.other", 1),
            ("diskAnalysis.header.total", 1),
            ("diskAnalysis.scan.current", 1),
            ("diskAnalysis.scan.count.other", 1),
            ("diskAnalysis.scan.elapsed", 1),
            ("diskAnalysis.scan.remaining", 1),
            ("diskAnalysis.others.one", 1),
            ("diskAnalysis.others.other", 1),
            ("diskAnalysis.sizeNotMeasured", 0),
            ("diskAnalysis.tile.sizeShare", 2),
            ("diskAnalysis.hover.sizeShare", 2),
            ("diskAnalysis.tile.accessibility", 3),
            ("diskAnalysis.overflow.accessibility", 2)
        ]
        // Compatible with positional parameters (%1$@): residue file
        // subtitles use this layout
        let placeholder = /%(?:\d+\$)?(?:@|lld)/
        for (key, argCount) in expectations {
            let value = L10n.tr(key)
            #expect(!isFallback(value, key: key), "\(key) not localized")
            let count = value.matches(of: placeholder).count
            #expect(count == argCount, "\(key) has \(count) placeholders, the call site passes \(argCount) arguments")
        }
    }

    /// The two singular/plural keys must keep the same placeholder layout.
    ///
    /// The caller passes arguments in the same order for both forms; if
    /// `.one` omits a `%lld`, the `%@` before it receives the integer;
    /// CFString dereferences the integer as an object pointer and the UI
    /// crashes as soon as it renders (address 0x1). Hence the placeholder
    /// sequences are compared one by one here.
    @Test func pluralVariantsSharePlaceholderLayout() {
        let pairs = [
            "count.items",
            "clean.helpSelected",
            "welcome.projectRoots",
            "clean.confirm.summary",
            "clean.confirm.listCount",
            "clean.progress.cleaned",
            "clean.result.doneWithFailures",
            "scan.banner.found",
            "scan.foundFinishing",
            "toast.reclaimedWithFailures",
            "apps.residueSummary",
            "apps.confirm.summary",
            "apps.confirm.running",
            "diskAnalysis.header.folders",
            "diskAnalysis.header.files",
            "diskAnalysis.scan.count",
            "diskAnalysis.others"
        ]
        let placeholder = /%(?:\d+\$)?(?:@|lld)/
        for base in pairs {
            let one = L10n.tr("\(base).one").matches(of: placeholder).map { String($0.output) }
            let other = L10n.tr("\(base).other").matches(of: placeholder).map { String($0.output) }
            #expect(!isFallback(L10n.tr("\(base).one"), key: "\(base).one"), "\(base).one not localized")
            #expect(!isFallback(L10n.tr("\(base).other"), key: "\(base).other"), "\(base).other not localized")
            #expect(one == other, "\(base) .one and .other placeholders differ: \(one) vs \(other)")
        }
    }

    /// Runs all singular/plural keys with the real argument shapes from the
    /// call sites: placeholders must be substituted, and none may remain —
    /// this directly covers the "%@ receives an integer" crash.
    @Test func pluralKeysSubstituteWithCallSiteArguments() {
        let calls: [(key: String, args: [CVarArg])] = [
            ("count.items.one", [1]),
            ("count.items.other", [7]),
            ("clean.helpSelected.one", [1]),
            ("clean.helpSelected.other", [7]),
            ("welcome.projectRoots.one", [1]),
            ("welcome.projectRoots.other", [3]),
            ("clean.confirm.summary.one", [1, "2.1 GB"]),
            ("clean.confirm.summary.other", [5, "2.1 GB"]),
            ("clean.confirm.listCount.one", [1]),
            ("clean.confirm.listCount.other", [5]),
            ("clean.progress.cleaned.one", [1]),
            ("clean.progress.cleaned.other", [5]),
            ("clean.result.doneWithFailures.one", [1]),
            ("clean.result.doneWithFailures.other", [5]),
            ("scan.banner.found.one", [1, "2.1 GB"]),
            ("scan.banner.found.other", [5, "2.1 GB"]),
            ("scan.foundFinishing.one", [1]),
            ("scan.foundFinishing.other", [5]),
            ("toast.reclaimedWithFailures.one", ["2.1 GB", 1]),
            ("toast.reclaimedWithFailures.other", ["2.1 GB", 5]),
            ("apps.residueSummary.one", [1]),
            ("apps.residueSummary.other", [5]),
            ("apps.confirm.summary.one", [1, "2.1 GB"]),
            ("apps.confirm.summary.other", [5, "2.1 GB"]),
            ("apps.confirm.running.one", [1]),
            ("apps.confirm.running.other", [3]),
            ("diskAnalysis.header.folders.one", [1]),
            ("diskAnalysis.header.folders.other", [3]),
            ("diskAnalysis.header.files.one", [1]),
            ("diskAnalysis.header.files.other", [4]),
            ("diskAnalysis.scan.count.one", [1]),
            ("diskAnalysis.scan.count.other", [7]),
            ("diskAnalysis.others.one", [1]),
            ("diskAnalysis.others.other", [18])
        ]
        for (key, args) in calls {
            let value = String(format: L10n.tr(key), arguments: args)
            #expect(!isFallback(value, key: key), "\(key) not localized")
            #expect(!value.contains("%@"), "\(key) leftover %@")
            #expect(!value.contains("%lld"), "\(key) leftover %lld")
        }
    }
}
