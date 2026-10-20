import Foundation
import Testing

@testable import Mackit

@MainActor
struct CleanupScopeTests {
    private func makeVM() -> AppViewModel {
        let vm = AppViewModel(statsPolling: false)
        // The VM's init reads the real shared settings file, so a developer
        // machine that has used the remember prompt would otherwise leak its
        // saved row selection into the tests. Declare the starting state.
        vm.generalSelectedRows = nil
        vm.autoSelectRisk = .none
        return vm
    }

    private func item(_ ruleID: String, _ name: String, category: JunkCategory, risk: RiskLevel, size: Int64) -> JunkItem {
        JunkItem(
            ruleID: ruleID,
            title: name,
            detail: name,
            path: "/tmp/\(name)",
            category: category,
            risk: risk,
            size: size
        )
    }

    /// Two developer-feature items and two general-feature items, with real
    /// rule ids so the general page's layout rows pick them up.
    private func seed(_ vm: AppViewModel) {
        vm.apply(.discovered([
            item("xcode.deriveddata", "deriveddata", category: .xcode, risk: .safe, size: 100),
            item("go.mod-download", "gomodcache", category: .go, risk: .review, size: 50),
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
            item("trash.home", "trash", category: .trash, risk: .caution, size: 80),
        ]))
    }

    /// Checks the given items the way the table does (through `toggle`, which
    /// also invalidates the selection-stats cache).
    private func select(_ titles: [String], in vm: AppViewModel) {
        for item in vm.items where vm.isSelected(item) != titles.contains(item.title) {
            vm.toggle(item)
        }
    }

    @Test func everyCategoryHasAScope() {
        // Both features are covered, and no category is left behind
        #expect(JunkCategory.allCases.allSatisfy {
            $0.scope == .developer || $0.scope == .general
        })
        #expect(JunkCategory.allCases.contains { $0.scope == .developer })
        #expect(JunkCategory.allCases.contains { $0.scope == .general })
        // The junk categories belong to the general module
        #expect(JunkCategory.browser.scope == .general)
        #expect(JunkCategory.language.scope == .general)
        #expect(JunkCategory.downloads.scope == .general)
        #expect(JunkCategory.system.scope == .general)
        #expect(JunkCategory.trash.scope == .general)
        // Toolchains and app management stay in the main window
        #expect(JunkCategory.xcode.scope == .developer)
        #expect(JunkCategory.ide.scope == .developer)
        #expect(JunkCategory.apps.scope == .developer)
        #expect(JunkCategory.projects.scope == .developer)
    }

    @Test func scopeTitlesAreLocalized() {
        for scope in CleanupScope.allCases {
            let titleKey = "scope.\(scope.rawValue).title"
            let summaryKey = "scope.\(scope.rawValue).summary"
            #expect(L10n.tr(titleKey) != titleKey, "\(scope.rawValue) 标题未本地化")
            #expect(L10n.tr(summaryKey) != summaryKey, "\(scope.rawValue) 说明未本地化")
        }
    }

    @Test func windowStartsOnTheDeveloperFeature() {
        let vm = makeVM()
        #expect(vm.showsGeneralCleanup == false)
        #expect(vm.cleanupScope == .developer)
    }

    @Test func generalPageSwitchesTheActiveScope() {
        let vm = makeVM()
        vm.showGeneralCleanup()
        #expect(vm.showsGeneralCleanup)
        #expect(vm.cleanupScope == .general)

        // Any category row leaves the general page again
        vm.selectCategory(.go)
        #expect(vm.showsGeneralCleanup == false)
        #expect(vm.cleanupScope == .developer)
        #expect(vm.selectedCategory == .go)
    }

    @Test func visibleItemsFollowTheActiveFeature() {
        let vm = makeVM()
        seed(vm)

        #expect(Set(vm.visibleItems.map(\.title)) == ["deriveddata", "gomodcache"])

        vm.showGeneralCleanup()
        #expect(Set(vm.visibleItems.map(\.title)) == ["chromecache", "trash"])
    }

    @Test func sidebarTotalsSplitByFeatureWhileThePanelStaysGlobal() {
        let vm = makeVM()
        seed(vm)

        #expect(vm.developerItemCount == 2)
        #expect(vm.developerTotalSize == 150)
        // The tray panel reports the grand total across both features
        #expect(vm.totalSize == 430)
        // The general page's header reports its own total
        #expect(vm.generalTotalSize == 280)

        vm.showGeneralCleanup()
        #expect(vm.developerItemCount == 2, "侧栏始终是开发者特性")
        #expect(vm.generalTotalSize == 280)
    }

    @Test func sidebarCategoriesStayOnTheDeveloperFeature() {
        let vm = makeVM()
        seed(vm)
        vm.showGeneralCleanup()

        #expect(vm.developerCategories.contains(.xcode))
        #expect(vm.developerCategories.contains(.go))
        #expect(!vm.developerCategories.contains(.browser))
        #expect(!vm.developerCategories.contains(.trash))
    }

    @Test func toolbarSelectionTracksTheActiveFeatureOnly() {
        let vm = makeVM()
        seed(vm)
        select(["deriveddata", "chromecache"], in: vm)

        #expect(Set(vm.scopeSelectedItems.map(\.title)) == ["deriveddata"])
        #expect(vm.scopeSelectedSize == 100)

        vm.showGeneralCleanup()
        #expect(Set(vm.scopeSelectedItems.map(\.title)) == ["chromecache"])
        #expect(vm.scopeSelectedSize == 200)
    }

    @Test func cleanTargetsFollowTheRequestedFeature() {
        let vm = makeVM()
        seed(vm)
        select(["deriveddata", "chromecache"], in: vm)

        // The window's clean button cleans the active feature's selection
        vm.requestClean()
        #expect(vm.cleanPhase == .confirming)
        #expect(Set(vm.selectedItems.map(\.title)) == ["deriveddata"])
        #expect(vm.selectedSize == 100)

        // The tray one-click clean sweeps every feature
        vm.requestClean(allScopes: true)
        #expect(Set(vm.selectedItems.map(\.title)) == ["deriveddata", "chromecache"])
        #expect(vm.selectedSize == 300)
    }

    @Test func generalRowsArePreCheckedUpToReview() {
        // Lemon's safety model: the general module's safe and review rows
        // arrive checked, caution rows never do — independent of the
        // developer feature's auto-select setting (here "none").
        let vm = makeVM()
        seed(vm)

        #expect(vm.selection.contains("browser.chrome-cache::/tmp/chromecache"))
        #expect(!vm.selection.contains("trash.home::/tmp/trash"))
        // Developer items still respect the setting
        #expect(!vm.selection.contains("xcode.deriveddata::/tmp/deriveddata"))
        #expect(!vm.selection.contains("go.mod-download::/tmp/gomodcache"))
    }

    @Test func generalRowsAggregateTheirRulesItems() {
        let vm = makeVM()
        vm.apply(.discovered([
            JunkItem(ruleID: "language.lproj", title: "ja.lproj", detail: "Foo",
                     path: "/tmp/ja.lproj", category: .language, risk: .review, size: 10),
            JunkItem(ruleID: "language.lproj", title: "fr.lproj", detail: "Foo",
                     path: "/tmp/fr.lproj", category: .language, risk: .review, size: 20),
            JunkItem(ruleID: "browser.chrome-cache", title: "Default/Cache", detail: "Chrome 缓存",
                     path: "/tmp/chrome", category: .browser, risk: .safe, size: 200),
        ]))

        let rows = vm.generalCleanGroups.flatMap(\.rows)
        let language = rows.first { $0.row.id == "language" }
        let chrome = rows.first { $0.row.id == "browser.chrome" }

        #expect(language?.items.count == 2)
        #expect(language?.size == 30)
        #expect(language?.isFullySelected == true, "review 行默认勾选")
        #expect(chrome?.items.count == 1)
        #expect(chrome?.size == 200)
        // Rows with nothing found still show up, for the checklist effect
        #expect(rows.contains { $0.row.id == "trash.home" && $0.items.isEmpty })
    }

    @Test func rowToggleChecksEveryItemOfTheRow() {
        let vm = makeVM()
        vm.apply(.discovered([
            JunkItem(ruleID: "language.lproj", title: "ja.lproj", detail: "Foo",
                     path: "/tmp/ja.lproj", category: .language, risk: .review, size: 10),
            JunkItem(ruleID: "language.lproj", title: "fr.lproj", detail: "Foo",
                     path: "/tmp/fr.lproj", category: .language, risk: .review, size: 20),
        ]))
        let row = GeneralCleanLayout.rows.first { $0.id == "language" }!

        vm.setRowSelected(row, selected: false)
        #expect(vm.selection.isEmpty)

        vm.setRowSelected(row, selected: true)
        #expect(vm.selection.count == 2)
    }

    private func generalGroup(_ group: GeneralCleanGroup, in vm: AppViewModel) -> AppViewModel.GeneralRuleGroupState {
        vm.generalCleanGroups.first { $0.group == group }!
    }

    /// The group header is the toggle for all of the group's rows at once:
    /// every item of every row moves — including the aggregated language-file
    /// entries — and the other group is untouched.
    @Test func groupToggleChecksEveryRowOfTheGroup() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("system.logs", "Foo.log", category: .system, risk: .safe, size: 100),
            item("system.crashreporter", "Foo.crash", category: .system, risk: .safe, size: 60),
            item("language.lproj", "ja.lproj", category: .language, risk: .review, size: 20),
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
        ]))

        vm.setGroupSelected(.system, selected: false)
        #expect(Set(vm.selection) == ["browser.chrome-cache::/tmp/chromecache"],
                "Unchecking the system group only moves that group's rows")

        vm.setGroupSelected(.system, selected: true)
        #expect(vm.selection.count == 4, "Re-checking restores the whole group, language entries included")

        vm.setGroupSelected(.browser, selected: false)
        #expect(vm.selection.count == 3, "The browser group toggles independently")
    }

    /// The group header's checkbox mirrors the rows: filled when every row
    /// with findings is checked, half-filled while any row is partially
    /// curated, empty once nothing in the group is selected.
    @Test func groupCheckboxReflectsPartialSelection() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("system.logs", "Foo.log", category: .system, risk: .safe, size: 100),
            item("system.crashreporter", "Foo.crash", category: .system, risk: .safe, size: 60),
        ]))

        #expect(generalGroup(.system, in: vm).isFullySelected, "Fully checked under the default pre-check")
        #expect(!generalGroup(.system, in: vm).isPartiallySelected)

        let crashRow = GeneralCleanLayout.rows(of: .system).first { $0.id == "system.crashreporter" }!
        vm.setRowSelected(crashRow, selected: false)
        #expect(!generalGroup(.system, in: vm).isFullySelected)
        #expect(generalGroup(.system, in: vm).isPartiallySelected, "Half-filled while one row is unchecked")

        vm.setGroupSelected(.system, selected: false)
        #expect(!generalGroup(.system, in: vm).isFullySelected)
        #expect(!generalGroup(.system, in: vm).isPartiallySelected, "Empty once nothing is selected")
    }

    /// A group whose rows found nothing has nothing to toggle: it reads
    /// unselected rather than "all checked", and the toggle changes nothing.
    @Test func groupWithNoFindingsReadsUnselected() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
        ]))

        let system = generalGroup(.system, in: vm)
        #expect(!system.isFullySelected, "A group with no findings is not selected")
        #expect(!system.isPartiallySelected)
        #expect(system.rows.allSatisfy { $0.items.isEmpty })

        vm.setGroupSelected(.system, selected: true)
        #expect(Set(vm.selection) == ["browser.chrome-cache::/tmp/chromecache"],
                "Toggling an empty group is a no-op")
    }

    /// The same path targeted by two rules — an app's log directory is both a
    /// residue entry of the app scan and a child of the user-logs rule — must
    /// be listed once, or the same bytes count twice.
    @Test func samePathIsOnlyListedOnce() {        let vm = makeVM()
        // The static rules stream in first (apply), so the generic rule owns
        // the path
        vm.apply(.discovered([
            item("system.logs", "Foo", category: .system, risk: .safe, size: 100),
        ]))
        // The app scan then finds the same path as residue: it must not
        // re-list it
        vm.mergeDiscovered([
            JunkItem(ruleID: "app.residue", title: "Foo", detail: "Foo · Logs",
                     path: "/tmp/Foo", category: .apps, risk: .safe, size: 100,
                     bundleID: "com.example.foo", appKind: .residue(.logs)),
        ])

        #expect(vm.items.count == 1)
        #expect(vm.items.first?.ruleID == "system.logs")
        #expect(vm.totalSize == 100, "同一路径不能重复计数")
    }

    /// A cancelled confirmation must not leave its scope filter behind: the
    /// other feature's page would then see an empty selection.
    @Test func cancellingConfirmationClearsTheCleanIntent() {
        let vm = makeVM()
        seed(vm)
        select(["deriveddata", "chromecache"], in: vm)

        vm.requestClean()
        #expect(Set(vm.selectedItems.map(\.title)) == ["deriveddata"])
        vm.cancelConfirmation()

        vm.showGeneralCleanup()
        #expect(Set(vm.scopeSelectedItems.map(\.title)) == ["chromecache"])
        #expect(vm.scopeSelectedSize == 200)
    }

    /// The built-in default (safe + review pre-checked) reports "nothing to
    /// remember"; a hand-curated selection reports a difference.
    @Test func selectionDiffersFromDefaultIsDetected() {
        let vm = makeVM()
        seed(vm)

        #expect(!vm.generalSelectionDiffersFromSaved(), "默认勾选无需提醒")

        let language = GeneralCleanLayout.rows.first { $0.id == "language" }
        vm.setRowSelected(GeneralCleanLayout.rows.first { $0.id == "browser.chrome" }!, selected: false)
        vm.setRowSelected(language!, selected: true)
        #expect(vm.generalSelectionDiffersFromSaved())
    }

    @Test func savedSelectionReplacesTheDefaultOnLaterScans() {
        let vm = makeVM()
        // Pretend the user once saved "only the Chrome row"
        vm.generalSelectedRows = ["browser.chrome"]

        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
            item("language.lproj", "ja.lproj", category: .language, risk: .review, size: 20),
            item("trash.home", "trash", category: .trash, risk: .caution, size: 80),
        ]))

        #expect(Set(vm.selection) == ["browser.chrome-cache::/tmp/chromecache"],
                "保存过的勾选取代内置默认")
    }

    @Test func rememberPromptOnlyShowsForGeneralCleansWithChanges() {
        let vm = makeVM()
        seed(vm)
        // A language-file item, so the curated selection below stays non-empty
        vm.apply(.discovered([
            JunkItem(ruleID: "language.lproj", title: "ja.lproj", detail: "Foo",
                     path: "/tmp/ja.lproj", category: .language, risk: .review, size: 20),
        ]))

        // No change yet: nothing to remember
        vm.requestClean()
        #expect(!vm.showsRememberGeneralPrompt)

        // Curate differently, then clean the general module
        vm.showGeneralCleanup()
        vm.setRowSelected(GeneralCleanLayout.rows.first { $0.id == "browser.chrome" }!, selected: false)
        vm.requestClean()
        #expect(vm.showsRememberGeneralPrompt)

        // The developer feature never prompts
        vm.cancelConfirmation()
        vm.selectCategory(.go)
        vm.requestClean()
        #expect(!vm.showsRememberGeneralPrompt)

        // Neither does the tray's one-click sweep
        vm.requestClean(allScopes: true)
        #expect(!vm.showsRememberGeneralPrompt)
    }
}
