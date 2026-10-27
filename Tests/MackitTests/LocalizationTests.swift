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
            "toast.copied",
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
            "apps.confirm.leftoverMore.one", "apps.confirm.leftoverMore.other", "apps.confirm.leftoverAction",
            "apps.ctx.uninstallWithResidue", "apps.ctx.residueOnly",
            "settings.includeApps", "settings.includeAppsHint",
            "sidebar.appUninstall", "sidebar.appUninstall.help",
            "apps.tool.header", "apps.tool.rescanning", "apps.tool.rescan.help",
            "apps.tool.search", "apps.tool.empty.title", "apps.tool.empty.message",
            "apps.tool.noMatch.title", "apps.tool.noMatch.message",
            "apps.tool.selected", "apps.tool.uninstallSelected",
            "apps.tool.lastOpened", "apps.tool.neverOpened",
            "apps.tool.lastOpenedUnavailable", "apps.tool.lastOpenedUnavailableHint",
            "permission.openSettings", "permission.openSettings.help",
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
            "clean.confirm.languageTitle", "clean.confirm.languageMessage",
            "clean.result.movedToTrash", "toast.moved",
            "toast.alreadyInTrash",
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
            "diskAnalysis.skipped.action",
            "diskAnalysis.others.one", "diskAnalysis.others.other",
            "diskAnalysis.others.help", "diskAnalysis.others.enter.help",
            "diskAnalysis.sizeNotMeasured",
            "diskAnalysis.tile.sizeShare", "diskAnalysis.hover.sizeShare",
            "diskAnalysis.tile.accessibility", "diskAnalysis.overflow.accessibility",
            "format.gigabytes.compact", "format.megabytes.compact", "format.kilobytes.compact",
            "format.terabytes.compact", "format.bytes.compact",
            "sidebar.homebrew", "sidebar.homebrew.help",
            "homebrew.title", "homebrew.loading", "homebrew.header.version",
            "homebrew.snapshot.unusable",
            "homebrew.section.installed", "homebrew.section.upgrade",
            "homebrew.section.install",
            "homebrew.section.services", "homebrew.section.diagnostics", "homebrew.section.config",
            "homebrew.section.badge",
            "homebrew.stat.formulae", "homebrew.stat.casks", "homebrew.stat.cache",
            "homebrew.stat.cellar", "homebrew.stat.separator",
            "homebrew.filter.all", "homebrew.filter.formula", "homebrew.filter.cask",
            "homebrew.dependencyFilter.all", "homebrew.dependencyFilter.onlyDependencies",
            "homebrew.dependencyFilter.excludeDependencies", "homebrew.dependencyFilter.help",
            "homebrew.dependencyFilter.title",
            "homebrew.searchPlaceholder", "homebrew.kind.formula", "homebrew.kind.cask",
            "homebrew.install.placeholder", "homebrew.install.clear",
            "homebrew.install.searching", "homebrew.install.prompt",
            "homebrew.install.promptHelp", "homebrew.install.noResults",
            "homebrew.install.noResultsHelp", "homebrew.install.failed",
            "homebrew.install.action", "homebrew.install.actionHelp",
            "homebrew.install.installed", "homebrew.install.installedBadge",
            "homebrew.package.outdated", "homebrew.package.pinned", "homebrew.package.upgrade",
            "homebrew.packages.empty", "homebrew.outdated.allLatest",
            "homebrew.detail.noSelection", "homebrew.detail.noSelectionHelp",
            "homebrew.detail.title", "homebrew.detail.degraded", "homebrew.detail.degradedHelp",
            "homebrew.detail.installed", "homebrew.detail.latest", "homebrew.detail.latestUnknown",
            "homebrew.detail.installDate", "homebrew.detail.installReason",
            "homebrew.detail.reason.onRequest", "homebrew.detail.reason.dependency",
            "homebrew.detail.reason.bottle", "homebrew.detail.reason.source",
            "homebrew.detail.license", "homebrew.detail.source", "homebrew.detail.size",
            "homebrew.detail.homepage", "homebrew.detail.dependencies",
            "homebrew.detail.noDependencies", "homebrew.detail.dependents",
            "homebrew.detail.noDependents", "homebrew.detail.blocksUninstall",
            "homebrew.detail.upgrade", "homebrew.detail.upgradeAllAction",
            "homebrew.detail.upgradeAllHelp", "homebrew.detail.upgradeAction",
            "homebrew.detail.uninstall", "homebrew.detail.uninstallHelp",
            "homebrew.detail.uninstallAction", "homebrew.detail.uninstallConfirm",
            "homebrew.detail.uninstallConfirmNote", "homebrew.detail.uninstallConfirmAction",
            "homebrew.services.filter.all", "homebrew.services.filter.running",
            "homebrew.services.filter.stopped", "homebrew.services.loading",
            "homebrew.services.failed", "homebrew.services.empty", "homebrew.services.emptyHelp",
            "homebrew.services.pid", "homebrew.services.start", "homebrew.services.stop",
            "homebrew.services.restart", "homebrew.services.status.running",
            "homebrew.services.status.stopped", "homebrew.services.status.none",
            "homebrew.services.status.scheduled", "homebrew.services.status.error",
            "homebrew.services.status.unknown", "homebrew.services.status.other",
            "homebrew.diagnostics.rerun", "homebrew.diagnostics.copy",
            "homebrew.diagnostics.running", "homebrew.diagnostics.empty",
            "homebrew.config.loading", "homebrew.config.empty",
            "homebrew.config.group.homebrew", "homebrew.config.group.system",
            "homebrew.config.copy",
            "homebrew.action.refresh", "homebrew.action.refresh.help",
            "homebrew.action.cleanup", "homebrew.action.cleanup.help",
            "homebrew.action.autoremove", "homebrew.action.autoremove.help",
            "homebrew.action.copy",
            "homebrew.running.cleanup", "homebrew.running.autoremove",
            "homebrew.running.upgradeAll", "homebrew.running.upgrade",
            "homebrew.running.uninstall", "homebrew.running.install",
            "homebrew.running.service",
            "homebrew.progress.count", "homebrew.progress.steps.one",
            "homebrew.progress.steps.other", "homebrew.progress.elapsed",
            "homebrew.progress.openLog", "homebrew.progress.logTitle",
            "homebrew.progress.logEmpty", "homebrew.progress.copyLog",
            "homebrew.progress.copied",
            "homebrew.result.cleaned", "homebrew.result.cleanedNone",
            "homebrew.result.autoremovedNone", "homebrew.result.upgradedAll",
            "homebrew.result.upgraded", "homebrew.result.uninstalled",
            "homebrew.result.installed",
            "homebrew.result.serviceStarted", "homebrew.result.serviceStopped",
            "homebrew.result.serviceRestarted", "homebrew.result.failed",
            "homebrew.error.brewUnavailable", "homebrew.error.cleanupFailed",
            "homebrew.error.autoremoveFailed", "homebrew.error.actionFailed",
            "homebrew.notInstalled.title", "homebrew.notInstalled.explain",
            "homebrew.notInstalled.action",
            "homebrew.notInstalled.commandCaption",
            "homebrew.notInstalled.refresh", "homebrew.notInstalled.refresh.help",
            "sidebar.largeFiles", "sidebar.largeFiles.help",
            "largeFiles.title", "largeFiles.header.preset",
            "largeFiles.summary.one", "largeFiles.summary.other",
            "largeFiles.tool.threshold", "largeFiles.tool.threshold.help",
            "largeFiles.sort.sizeDescending", "largeFiles.sort.sizeAscending",
            "largeFiles.sort.name", "largeFiles.sort.nameDescending",
            "largeFiles.sort.recentModified", "largeFiles.sort.earliestModified",
            "largeFiles.tool.search", "largeFiles.tool.trashSelected",
            "largeFiles.tool.rescan.help",
            "largeFiles.start.explain", "largeFiles.start.protected",
            "largeFiles.start.protected.help",
            "largeFiles.scan.title",
            "largeFiles.scan.directories.one", "largeFiles.scan.directories.other",
            "largeFiles.scan.found.one", "largeFiles.scan.found.other",
            "largeFiles.scan.elapsed", "largeFiles.scan.streaming",
            "largeFiles.partial",
            "largeFiles.unreadable.title", "largeFiles.unreadable.message",
            "largeFiles.empty.title", "largeFiles.empty.message",
            "largeFiles.empty.partial", "largeFiles.empty.partial.hint",
            "largeFiles.confirm.title",
            "largeFiles.confirm.summary.one", "largeFiles.confirm.summary.other",
            "largeFiles.confirm.reviewMessage",
            "largeFiles.confirm.action.trash", "largeFiles.confirm.action.delete",
            "largeFiles.ctx.select", "largeFiles.ctx.deselect",
            "settings.crashLogs.header", "settings.crashLogs.collect",
            "settings.crashLogs.hint", "settings.crashLogs.empty",
            "settings.crashLogs.notice.off",
            "settings.crashLogs.deleteAll",
            "settings.crashLogs.deleteAllConfirm",
            "settings.crashLogs.deleteAllConfirmAction",
            "settings.crashLogs.deleteAllFailed.one",
            "settings.crashLogs.deleteAllFailed.other",
            "crashLogs.row.summary",
            "crashLogs.detail.title", "crashLogs.detail.process",
            "crashLogs.detail.version", "crashLogs.detail.versionValue",
            "crashLogs.detail.os", "crashLogs.detail.pid",
            "crashLogs.detail.signal", "crashLogs.detail.faultAddress",
            "crashLogs.detail.exception", "crashLogs.detail.backtrace",
            "crashLogs.detail.deleteConfirm",
            "crashLogs.process.app", "crashLogs.process.agent",
            "crashLogs.action.symbolicate", "crashLogs.action.symbolicating",
            "crashLogs.action.symbolicated", "crashLogs.action.symbolicateFailed",
            "crashLogs.action.reveal", "crashLogs.action.export",
            "crashLogs.action.delete",
            "crashLogs.symbolize.noImageRange", "crashLogs.symbolize.noOwnFrames",
            "crashLogs.symbolize.binaryMissing", "crashLogs.symbolize.binaryReplaced",
            "crashLogs.symbolize.atosFailed",
            "toast.crashLogDeleted", "toast.crashLogExported",
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

        let more = L10n.fmt("apps.confirm.leftoverMore.other", 5)
        #expect(more.contains("5"))
        #expect(!more.contains("%lld"))
        // The singular form carries the same placeholder layout, or the
        // %lld integer would land in the %@ slot and crash the render.
        let moreOne = L10n.fmt("apps.confirm.leftoverMore.one", 1)
        #expect(moreOne.contains("1"))
        #expect(!moreOne.contains("%lld"))

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

        // The dependency filter's menu items: option name beside the row
        // count choosing it would leave
        let dependencyOption = L10n.fmt("homebrew.dependencyFilter.count", "Manually installed", 52)
        #expect(dependencyOption.contains("Manually installed"))
        #expect(dependencyOption.contains("52"))
        #expect(!dependencyOption.contains("%1$@"))
        #expect(!dependencyOption.contains("%2$lld"))
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
            ("toast.moved", 1),
            ("toast.movedWithFailures.one", 2),
            ("toast.movedWithFailures.other", 2),
            ("clean.error.cannotRun", 1),
            ("clean.error.exitCode", 1),
            ("clean.confirm.summary.other", 2),
            ("clean.confirm.languageMessage", 1),
            ("clean.result.movedToTrash", 1),
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
            ("apps.confirm.leftoverMore.one", 1),
            ("apps.confirm.leftoverMore.other", 1),
            ("apps.tool.header", 2),
            ("apps.tool.selected", 2),
            ("apps.tool.lastOpened", 1),
            ("apps.tool.uninstallSelected", 1),
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
            ("diskAnalysis.overflow.accessibility", 2),
            ("homebrew.header.version", 2),
            ("homebrew.section.badge", 2),
            ("homebrew.dependencyFilter.count", 2),
            ("homebrew.progress.count", 2),
            ("homebrew.progress.steps.one", 1),
            ("homebrew.progress.steps.other", 1),
            ("homebrew.progress.elapsed", 1),
            ("homebrew.package.upgrade", 2),
            ("homebrew.detail.upgradeAction", 1),
            ("homebrew.detail.uninstallConfirm", 1),
            ("homebrew.services.pid", 1),
            ("homebrew.result.cleaned", 1),
            ("homebrew.result.autoremoved.one", 1),
            ("homebrew.result.autoremoved.other", 1),
            ("homebrew.progress.steps.one", 1),
            ("homebrew.progress.steps.other", 1),
            ("homebrew.result.upgraded", 1),
            ("homebrew.result.uninstalled", 1),
            ("homebrew.result.installed", 1),
            ("homebrew.result.serviceStarted", 1),
            ("homebrew.result.serviceStopped", 1),
            ("homebrew.result.serviceRestarted", 1),
            ("homebrew.result.failed", 1),
            ("crashLogs.row.summary", 3),
            ("crashLogs.detail.versionValue", 2),
            ("crashLogs.symbolize.binaryReplaced", 2),
            ("settings.crashLogs.deleteAllFailed.one", 1),
            ("settings.crashLogs.deleteAllFailed.other", 1)
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
            "toast.movedWithFailures",
            "apps.residueSummary",
            "apps.confirm.summary",
            "apps.confirm.running",
            "apps.confirm.leftoverMore",
            "diskAnalysis.header.folders",
            "diskAnalysis.header.files",
            "diskAnalysis.scan.count",
            "diskAnalysis.others",
            "homebrew.result.autoremoved",
            "homebrew.progress.steps",
            "settings.crashLogs.deleteAllFailed"
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
            ("toast.movedWithFailures.one", ["2.1 GB", 1]),
            ("toast.movedWithFailures.other", ["2.1 GB", 5]),
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
            ("diskAnalysis.others.other", [18]),
            ("homebrew.result.autoremoved.one", [1]),
            ("homebrew.result.autoremoved.other", [5]),
            ("homebrew.progress.steps.one", [1]),
            ("homebrew.progress.steps.other", [5]),
            ("settings.crashLogs.deleteAllFailed.one", [1]),
            ("settings.crashLogs.deleteAllFailed.other", [5])
        ]
        for (key, args) in calls {
            let value = String(format: L10n.tr(key), arguments: args)
            #expect(!isFallback(value, key: key), "\(key) not localized")
            #expect(!value.contains("%@"), "\(key) leftover %@")
            #expect(!value.contains("%lld"), "\(key) leftover %lld")
        }
    }
}
