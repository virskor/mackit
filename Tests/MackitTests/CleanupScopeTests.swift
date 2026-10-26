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

    private func item(
        _ ruleID: String, _ name: String, category: JunkCategory, risk: RiskLevel, size: Int64,
        appName: String? = nil
    ) -> JunkItem {
        JunkItem(
            ruleID: ruleID,
            title: name,
            detail: name,
            path: "/tmp/\(name)",
            category: category,
            risk: risk,
            size: size,
            appName: appName
        )
    }

    private func languageItem(_ code: String, app: String, size: Int64) -> JunkItem {
        JunkItem(
            ruleID: "language.lproj", title: "\(code).lproj", detail: "\(app) bundled language packs",
            path: "/tmp/\(app)/\(code).lproj", category: .language, risk: .review,
            size: size, appName: app
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
            #expect(L10n.tr(titleKey) != titleKey, "\(scope.rawValue) title not localized")
            #expect(L10n.tr(summaryKey) != summaryKey, "\(scope.rawValue) summary not localized")
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
        #expect(vm.developerItemCount == 2, "the sidebar always shows the developer feature")
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
        // arrive checked — except the rows that opt out (unused language
        // files) — and caution rows never do, independent of the developer
        // feature's auto-select setting (here "none").
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
            JunkItem(ruleID: "browser.chrome-cache", title: "Default/Cache", detail: "Chrome cache",
                     path: "/tmp/chrome", category: .browser, risk: .safe, size: 200),
        ]))

        let rows = vm.generalCleanGroups.flatMap(\.rows)
        let language = rows.first { $0.row.id == "language" }
        let chrome = rows.first { $0.row.id == "browser.chrome" }

        #expect(language?.items.count == 2)
        #expect(language?.size == 30)
        #expect(language?.isFullySelected == false,
                "unused language packs are opt-in, unlike every other review row")
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

    private func generalRow(_ rowID: String, in vm: AppViewModel) -> AppViewModel.GeneralRuleRowState {
        vm.generalCleanGroups.flatMap(\.rows).first { $0.row.id == rowID }!
    }

    /// The reported bug: a row the scan found nothing for looked like a
    /// checkbox but ignored every click, because its state could only be
    /// derived from items that did not exist. It now checks by hand.
    @Test func rowWithNoFindingsCanStillBeChecked() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
        ]))

        let trashRow = GeneralCleanLayout.rows.first { $0.id == "trash.home" }!
        #expect(generalRow("trash.home", in: vm).items.isEmpty)
        #expect(!generalRow("trash.home", in: vm).isFullySelected)

        vm.setRowSelected(trashRow, selected: true)
        #expect(generalRow("trash.home", in: vm).isFullySelected, "a row with no findings can still be checked")
        #expect(vm.handCheckedGeneralRows == ["trash.home"])
        // No items to move: the selection itself stays as it was
        #expect(Set(vm.selection) == ["browser.chrome-cache::/tmp/chromecache"])

        vm.setRowSelected(trashRow, selected: false)
        #expect(!generalRow("trash.home", in: vm).isFullySelected, "clicking once more unchecks it")
        #expect(vm.handCheckedGeneralRows.isEmpty)
    }

    /// The group header toggle also moves the rows that found nothing: their
    /// check lives outside the item selection, so "select all" has to cover
    /// them or the group would stay half-dead.
    @Test func groupToggleMovesRowsWithNoFindings() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
        ]))

        vm.setGroupSelected(.system, selected: true)
        #expect(generalGroup(.system, in: vm).rows.allSatisfy { $0.isFullySelected },
                "every row of the system junk group is checked, including rows with no content")
        #expect(vm.handCheckedGeneralRows.count == GeneralCleanLayout.rows(of: .system).count)
        #expect(!generalGroup(.browser, in: vm).rows.contains { $0.isCheckedByHand }, "the other group is unaffected")

        vm.setGroupSelected(.system, selected: false)
        #expect(generalGroup(.system, in: vm).rows.allSatisfy { !$0.isFullySelected })
        #expect(vm.handCheckedGeneralRows.isEmpty)
    }

    /// The next scan restarts from the remembered selection, so a remembered
    /// row shows checked even when the scan finds nothing for it — and an
    /// unchanged saved selection must not read as a difference worth a prompt.
    @Test func rememberedRowsStayCheckedWhenTheScanFindsNothing() {
        let vm = makeVM()
        vm.generalSelectedRows = ["trash.home"]

        vm.resetGeneralRowChecks()
        #expect(vm.handCheckedGeneralRows == ["trash.home"])

        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
        ]))
        #expect(generalRow("trash.home", in: vm).isFullySelected, "the remembered check is still in effect when a new scan begins")
        #expect(!vm.generalSelectionDiffersFromSaved(), "the saved check is shown as-is; no reminder should pop up")

        vm.generalSelectedRows = nil
        vm.resetGeneralRowChecks()
        #expect(vm.handCheckedGeneralRows.isEmpty, "nothing has been saved, so there are no hand-checked rows")
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

    /// A group whose rows found nothing reads unselected rather than "all
    /// checked". There are no items to move, but the rows still record the
    /// check — that record is what makes an item-less row respond to clicks.
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
                "there are no items to move; checking does not change the selection set")
        #expect(generalGroup(.system, in: vm).rows.allSatisfy { $0.isFullySelected },
                "but every row records this check")
        #expect(!generalGroup(.system, in: vm).isFullySelected, "the whole group still reads as unselected: there is nothing to select")
    }

    /// The selection is the user's standing intent, so a clean must not wipe
    /// it: clicking clean and finding every row unchecked makes the page read
    /// as "nothing selected" and forces a re-curate before the next sweep.
    /// Rows whose items were all cleaned keep their check as a hand-checked
    /// row, since there are no items left to derive it from.
    @Test func finishedCleanKeepsTheUsersSelection() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("xcode.deriveddata", "DerivedData", category: .xcode, risk: .safe, size: 500),
            item("system.logs", "Foo.log", category: .system, risk: .safe, size: 100),
            item("language.lproj", "ja.lproj", category: .language, risk: .review, size: 20),
        ]))
        vm.setGroupSelected(.system, selected: true)
        #expect(generalGroup(.system, in: vm).rows.allSatisfy { $0.isFullySelected })

        let cleaned = Set(vm.items.filter { $0.category.scope == .general }.map(\.id))
        vm.removeCleanedItems(cleaned)

        #expect(Set(vm.items.map(\.title)) == ["DerivedData"], "the other feature's items are unaffected")
        #expect(vm.selection.isEmpty, "deleted ids do not stay in the selection set")
        #expect(vm.handCheckedGeneralRows == Set(GeneralCleanLayout.rows(of: .system).map(\.id)),
                "emptied rows keep their check as a hand-checked row; the page still shows the user's check result")
        #expect(generalGroup(.system, in: vm).rows.allSatisfy { $0.isFullySelected },
                "every row stays checked after the clean finishes, including rows with no findings")
        // The other feature's selection is untouched
        #expect(!vm.isSelected(vm.items.first { $0.title == "DerivedData" } ?? vm.items[0]))
    }

    /// A cancelled clean keeps everything the user had: the un-cleaned items
    /// stay selected, the rows that were already deleted keep their check as
    /// hand-checked rows, and the rest stay as they were. Nothing is
    /// consumed — the user stopped on purpose and can resume where they left
    /// off.
    @Test func cancelledCleanKeepsRowsWithNoFindingsChecked() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("system.logs", "Foo.log", category: .system, risk: .safe, size: 100),
            item("system.crashreporter", "Foo.crash", category: .system, risk: .safe, size: 60),
        ]))
        vm.setGroupSelected(.system, selected: true)

        // Only the crash reports were deleted before the user hit stop
        let cleaned = Set(vm.items.filter { $0.ruleID == "system.crashreporter" }.map(\.id))
        vm.removeCleanedItems(cleaned)

        #expect(generalRow("system.crashreporter", in: vm).isFullySelected, "a deleted row keeps its check: cancelling is not abandoning the check")
        #expect(generalRow("system.logs", in: vm).isFullySelected, "items not yet cleaned are still checked")
        #expect(generalRow("trash.home", in: vm).isFullySelected, "an empty row's hand-check is kept: the user only paused")
        #expect(vm.handCheckedGeneralRows == Set(GeneralCleanLayout.rows(of: .system).map(\.id)),
                "the group toggle already hand-checked every row; cancelling the clean does not clear any additional row")
    }

    /// A developer-feature clean must not touch the general page's rows: the
    /// two features' selections are independent, and the hand-checked rows
    /// belong to the general module alone.
    @Test func developerCleanLeavesTheGeneralRowsChecked() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("xcode.deriveddata", "DerivedData", category: .xcode, risk: .safe, size: 500),
            item("system.logs", "Foo.log", category: .system, risk: .safe, size: 100),
        ]))
        vm.setGroupSelected(.system, selected: true)
        if let derived = vm.items.first(where: { $0.title == "DerivedData" }), !vm.isSelected(derived) {
            vm.toggle(derived)
        }

        let cleaned = Set(vm.items.filter { $0.category.scope == .developer }.map(\.id))
        vm.removeCleanedItems(cleaned)

        #expect(vm.items.count == 1, "only the developer clean item was deleted")
        #expect(generalGroup(.system, in: vm).rows.allSatisfy { $0.isFullySelected },
                "the junk page's check is kept as-is")
    }

    /// End-to-end through the real clean engine (temp files on disk): after
    /// cleaning, the selection the user made is still there — the deleted ids
    /// are gone from it, and the emptied rows keep their check.
    @Test func realCleanKeepsTheUsersSelection() async throws {
        let vm = makeVM()
        let unique = UUID().uuidString
        let logsPath = "/tmp/mackit-test-\(unique).log"
        let crashPath = "/tmp/mackit-test-\(unique).crash"
        FileManager.default.createFile(atPath: logsPath, contents: Data(repeating: 0, count: 100))
        FileManager.default.createFile(atPath: crashPath, contents: Data(repeating: 0, count: 60))
        defer {
            try? FileManager.default.removeItem(atPath: logsPath)
            try? FileManager.default.removeItem(atPath: crashPath)
        }
        vm.apply(.discovered([
            JunkItem(ruleID: "system.logs", title: "Foo.log", detail: "Foo.log",
                     path: logsPath, category: .system, risk: .safe, size: 100),
            JunkItem(ruleID: "system.crashreporter", title: "Foo.crash", detail: "Foo.crash",
                     path: crashPath, category: .system, risk: .safe, size: 60),
        ]))
        vm.setGroupSelected(.system, selected: true)
        vm.moveToTrash = false

        vm.beginClean()
        for _ in 0..<200 where vm.cleanPhase != .done {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(vm.cleanPhase == .done)
        #expect(vm.items.isEmpty)
        #expect(vm.selection.isEmpty, "deleted ids do not stay in the selection set")
        #expect(vm.handCheckedGeneralRows == Set(GeneralCleanLayout.rows(of: .system).map(\.id)),
                "emptied rows keep their check as a hand-checked row; the page still shows the user's check result")
        #expect(generalGroup(.system, in: vm).rows.allSatisfy { $0.isFullySelected },
                "every row stays checked after the clean finishes")
    }

    /// App junk is the general module's own row: every app's regenerable
    /// residue rolls up into it, safe, so it arrives pre-checked like every
    /// other safe row — a user can sweep caches without uninstalling anything.
    @Test func appJunkRowIsPreCheckedAndGroupsPerApp() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("app.junk", "com.example.foo", category: .appJunk, risk: .safe, size: 100, appName: "Foo"),
            item("app.junk", "com.example.bar", category: .appJunk, risk: .safe, size: 300, appName: "Bar"),
            // The same app's data residue stays in the uninstall flow
            item("app.residue", "com.example.foo.plist", category: .apps, risk: .review, size: 50, appName: "Foo"),
        ]))

        let row = generalRow("app.junk", in: vm)
        #expect(row.items.count == 2)
        #expect(row.size == 400)
        #expect(row.isFullySelected, "safe rows are checked by default")
        // The row is a general-scope row: the uninstall residue does not roll in
        #expect(!row.items.contains { $0.category == .apps })

        // Sub-rows: one per app, largest first
        #expect(row.subRows.map(\.id) == ["Bar", "Foo"])
        #expect(row.subRows.map(\.size) == [300, 100])
        #expect(row.subRows.allSatisfy { $0.isFullySelected })

        // Keeping one app's caches moves only that app's items
        let junkRow = GeneralCleanLayout.rows.first { $0.id == "app.junk" }!
        vm.setSubRowSelected(junkRow, key: "Foo", selected: false)
        #expect(generalRow("app.junk", in: vm).isPartiallySelected)
        #expect(Set(vm.selection) == ["app.junk::/tmp/com.example.bar"],
                "only Foo's caches are unchecked; Bar's are kept")
        // The other feature's selection is untouched by the sub-row toggle
        #expect(!vm.selection.contains("app.residue::/tmp/com.example.foo.plist"))

        // Re-checking through the row header restores the row's items — and
        // only those: the uninstall residue belongs to the other feature and
        // stays where it was
        vm.setRowSelected(junkRow, selected: true)
        #expect(generalRow("app.junk", in: vm).isFullySelected)
        #expect(vm.selection.count == 2)
        #expect(!vm.selection.contains("app.residue::/tmp/com.example.foo.plist"))
    }

    /// Language files group per language, so a single language can be kept
    /// while the rest is swept — the granularity Lemon's language list has.
    @Test func languageSubRowsGroupPerLanguage() {
        let vm = makeVM()
        vm.apply(.discovered([
            languageItem("ja", app: "Foo", size: 10),
            languageItem("ja", app: "Bar", size: 20),
            languageItem("fr", app: "Foo", size: 5),
        ]))

        let row = generalRow("language", in: vm)
        #expect(row.items.count == 3)
        #expect(row.subRows.count == 2)
        // Grouped by language code, largest group first
        #expect(row.subRows.map(\.id) == ["ja", "fr"])
        #expect(row.subRows.map(\.size) == [30, 5])
        #expect(row.subRows[0].itemIDs.count == 2, "the Japanese sub-row covers two apps' language packs")
        // The sub-row title is the language's own name, not the raw code
        #expect(!row.subRows[0].title.isEmpty)
        #expect(row.subRows[0].title != "ja")
        // …and its second line names the apps that ship it: the language
        // alone does not say which apps change when it is checked.
        #expect(row.subRows[0].detail?.contains("Foo") == true)
        #expect(row.subRows[0].detail?.contains("Bar") == true)

        // The row is opt-in, so it is checked by hand before the sub-row is
        // curated; the sub-row toggle then moves only its own language.
        let languageRow = GeneralCleanLayout.rows.first { $0.id == "language" }!
        vm.setRowSelected(languageRow, selected: true)
        #expect(Set(vm.selection) == [
            "language.lproj::/tmp/Foo/ja.lproj",
            "language.lproj::/tmp/Bar/ja.lproj",
            "language.lproj::/tmp/Foo/fr.lproj",
        ])
        vm.setSubRowSelected(languageRow, key: "fr", selected: false)
        #expect(generalRow("language", in: vm).isPartiallySelected)
        #expect(Set(vm.selection) == [
            "language.lproj::/tmp/Foo/ja.lproj",
            "language.lproj::/tmp/Bar/ja.lproj",
        ])
    }

    /// The second line of a sub-row only exists where the title cannot name
    /// the owner: per-app rows already do, and a language pack whose app could
    /// not be named adds nothing (the row header still covers it).
    @Test func subRowDetailOnlyNamesAppsForLanguageGroups() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("app.junk", "com.example.foo", category: .appJunk, risk: .safe, size: 40, appName: "Foo"),
            JunkItem(ruleID: "language.lproj", title: "ja.lproj", detail: "Foo",
                     path: "/tmp/anon/ja.lproj", category: .language, risk: .review, size: 10),
        ]))

        let appJunk = generalRow("app.junk", in: vm)
        #expect(!appJunk.subRows.isEmpty)
        #expect(appJunk.subRows.allSatisfy { $0.detail == nil })

        let language = generalRow("language", in: vm)
        #expect(language.subRows.count == 1)
        #expect(language.subRows[0].detail == nil, "an item carrying no app name adds no second line")
    }

    /// A row with no sub-rows stays a flat toggle; an item whose app could
    /// not be named is still covered by the row header.
    @Test func flatRowsHaveNoSubRows() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
        ]))
        let row = generalRow("browser.chrome", in: vm)
        #expect(row.row.subRowMode == .flat)
        #expect(row.subRows.isEmpty)
    }

    /// The remembered selection is persisted to the shared settings file —
    /// the "local config file" that restores the user's checkmarks on the
    /// next scan — and the restore shortcut is the way back out of it.
    @Test func rememberAndRestoreRoundTrip() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
            item("language.lproj", "ja.lproj", category: .language, risk: .review, size: 20),
            item("trash.home", "trash", category: .trash, risk: .caution, size: 80),
        ]))

        var written: [String: Any]?
        vm.settingsSink = { written = $0 }

        // Curate differently from the default, then remember it. The language
        // row is opt-in, so the curation is "only the language packs, no
        // browser cache" — checked by hand, then Chrome unchecked.
        let languageRow = GeneralCleanLayout.rows.first { $0.id == "language" }!
        vm.setRowSelected(languageRow, selected: true)
        vm.setRowSelected(GeneralCleanLayout.rows.first { $0.id == "browser.chrome" }!, selected: false)
        #expect(vm.generalSelectionDiffersFromSaved())
        vm.rememberGeneralSelection()
        #expect(vm.hasRememberedGeneralSelection)
        #expect(vm.generalSelectedRows == ["language"])
        #expect(written?["generalSelectedRows"] as? [String] == ["language"], "the remembered check must be written to the local config file")

        // Restoring the default drops the saved selection and re-applies the
        // built-in pre-check to what the current scan already found — no
        // rescan needed
        vm.restoreDefaultGeneralSelection()
        #expect(!vm.hasRememberedGeneralSelection)
        #expect(vm.generalSelectedRows == nil)
        #expect(written?["generalSelectedRows"] as? [String] == [], "restoring defaults must clear the saved check")
        #expect(Set(vm.selection) == ["browser.chrome-cache::/tmp/chromecache"],
                "after restoring, checks follow the built-in defaults: pre-checked rows only, so the opt-in language row stays unchecked")
        #expect(vm.handCheckedGeneralRows.isEmpty)
        #expect(!vm.generalSelectionDiffersFromSaved(), "after restoring it matches the defaults, so no reminder is needed")
    }

    /// Restoring defaults also unchecks a caution row the user had opted in:
    /// "defaults" means the built-in pre-check, nothing more.
    @Test func restoreDefaultUnchecksOptedInRows() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("trash.home", "trash", category: .trash, risk: .caution, size: 80),
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
        ]))
        vm.settingsSink = { _ in }

        vm.setRowSelected(GeneralCleanLayout.rows.first { $0.id == "trash.home" }!, selected: true)
        #expect(vm.selection.count == 2)

        vm.restoreDefaultGeneralSelection()
        #expect(Set(vm.selection) == ["browser.chrome-cache::/tmp/chromecache"])
        #expect(vm.handCheckedGeneralRows.isEmpty, "hand-checked rows are restored as well")
    }

    /// A remembered selection survives into the next scan's pre-check, which
    /// is the whole point of persisting it.
    @Test func rememberedSelectionReplacesTheDefaultOnTheNextScan() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
            item("language.lproj", "ja.lproj", category: .language, risk: .review, size: 20),
        ]))
        vm.settingsSink = { _ in }
        let languageRow = GeneralCleanLayout.rows.first { $0.id == "language" }!
        vm.setRowSelected(languageRow, selected: true)
        vm.setRowSelected(GeneralCleanLayout.rows.first { $0.id == "browser.chrome" }!, selected: false)
        vm.rememberGeneralSelection()

        // A later scan restarts from the remembered selection
        vm.resetGeneralRowChecks()
        #expect(vm.handCheckedGeneralRows == ["language"])
        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
            item("language.lproj", "ja.lproj", category: .language, risk: .review, size: 20),
        ]))
        #expect(Set(vm.selection) == ["language.lproj::/tmp/ja.lproj"],
                "the saved check replaces the built-in default")
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
        #expect(vm.totalSize == 100, "the same path must not be counted twice")
    }

    /// The same bytes are also double-counted when one entry *contains*
    /// another: Homebrew's cache directory is one app-junk entry, while the
    /// brew rule lists each download inside it. The coarser entry loses, so
    /// the total stays honest — and the finer entries stay listed, so nothing
    /// the user could clean before disappears.
    @Test func coarserEntryNeverRelistsWhatFinerEntriesCover() {
        let vm = makeVM()
        // The brew rule lists each download inside the cache directory
        vm.apply(.discovered([
            JunkItem(ruleID: "brew.cache", title: "foo--1.0", detail: "Homebrew",
                     path: "/tmp/Library/Caches/Homebrew/foo--1.0", category: .homebrew,
                     risk: .safe, size: 60),
            JunkItem(ruleID: "brew.cache", title: "bar--2.0", detail: "Homebrew",
                     path: "/tmp/Library/Caches/Homebrew/bar--2.0", category: .homebrew,
                     risk: .safe, size: 40),
        ]))

        // The app scan then finds the whole cache directory as app junk
        vm.mergeDiscovered([
            JunkItem(ruleID: "app.junk", title: "Homebrew", detail: "Homebrew's cache",
                     path: "/tmp/Library/Caches/Homebrew", category: .appJunk,
                     risk: .safe, size: 100, appName: "Homebrew"),
        ])

        #expect(vm.items.count == 2, "a coarse entry that contains already-listed content is not re-listed")
        #expect(vm.totalSize == 100, "the same space must not be counted twice")
        #expect(!vm.items.contains { $0.ruleID == "app.junk" })
        // The finer entries are still there and still cleanable
        #expect(vm.categoryCounts[.homebrew] == 2)
    }

    /// An app bundle must not swallow the language packs listed inside it:
    /// those are junk for a user who keeps the app, and the bundle's own
    /// uninstall does not replace them.
    @Test func appBundleDoesNotSwallowTheLanguagePacksInsideIt() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("app.bundle", "Foo.app", category: .apps, risk: .caution, size: 500, appName: "Foo"),
        ]))

        vm.mergeDiscovered([
            JunkItem(ruleID: "language.lproj", title: "ja.lproj", detail: "Foo bundled language packs",
                     path: "/Applications/Foo.app/Contents/Resources/ja.lproj",
                     category: .language, risk: .review, size: 20, appName: "Foo"),
        ])

        #expect(vm.items.count == 2, "language packs inside an app are listed independently")
        #expect(vm.categoryCounts[.language] == 1)
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

    /// The built-in default reports "nothing to remember"; a hand-curated
    /// selection reports a difference — whether a pre-checked row was
    /// unchecked or the opt-in language row was checked.
    @Test func selectionDiffersFromDefaultIsDetected() {
        let vm = makeVM()
        seed(vm)

        #expect(!vm.generalSelectionDiffersFromSaved(), "the default check needs no reminder")

        let chrome = GeneralCleanLayout.rows.first { $0.id == "browser.chrome" }!
        vm.setRowSelected(chrome, selected: false)
        #expect(vm.generalSelectionDiffersFromSaved())

        vm.setRowSelected(chrome, selected: true)
        #expect(!vm.generalSelectionDiffersFromSaved(), "back to the default")

        vm.setRowSelected(GeneralCleanLayout.rows.first { $0.id == "language" }!, selected: true)
        #expect(vm.generalSelectionDiffersFromSaved(), "opting the language row in is a curation as well")
    }

    /// A row whose entries all measure 0 bytes is skipped by the default
    /// pre-check (an empty cache holds nothing to reclaim), so it must not
    /// make the selection read as "curated" — otherwise the remember prompt
    /// sits there on every clean on a machine with one empty cache directory,
    /// asking to remember a selection the user never made.
    @Test func zeroSizedRowAloneDoesNotCountAsCuration() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
            item("app.junk", "com.example.foo", category: .appJunk, risk: .safe, size: 0, appName: "Foo"),
        ]))

        #expect(vm.selection == ["browser.chrome-cache::/tmp/chromecache"], "0-byte entries are not pre-checked")
        #expect(!vm.generalSelectionDiffersFromSaved(), "an empty cache row does not count as the user having changed the check")
        #expect(!vm.showsRememberGeneralPrompt)
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
                "the saved check replaces the built-in default")
    }

    @Test func rememberPromptOnlyShowsForGeneralCleansWithChanges() {
        let vm = makeVM()
        seed(vm)
        // A language-file item, so the curated selection below stays non-empty
        // — the language row is opt-in and has to be checked by hand.
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
        vm.setRowSelected(GeneralCleanLayout.rows.first { $0.id == "language" }!, selected: true)
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

    /// Remembering a selection is a deliberate act with a visible outcome, so
    /// it has to say so: the button's label changing from "remember" to
    /// "restore defaults" is the only other feedback, and a user who does not
    /// catch that has no way to tell whether the click landed.
    @Test func rememberingASelectionConfirmsWithAToast() {
        let vm = makeVM()
        vm.settingsSink = { _ in }
        vm.apply(.discovered([
            item("browser.chrome-cache", "chromecache", category: .browser, risk: .safe, size: 200),
            item("language.lproj", "ja.lproj", category: .language, risk: .review, size: 20),
        ]))
        vm.setRowSelected(GeneralCleanLayout.rows.first { $0.id == "language" }!, selected: true)
        vm.setRowSelected(GeneralCleanLayout.rows.first { $0.id == "browser.chrome" }!, selected: false)
        vm.dismissToast()

        vm.rememberGeneralSelection()

        #expect(vm.banner != nil, "there should be a notice after remembering the check")
        #expect(vm.banner?.style == .success)
        #expect(vm.hasRememberedGeneralSelection)
        #expect(vm.generalSelectedRows == ["language"], "the opt-in row was the curation that got remembered")
        // Restoring defaults confirms too — the state change is otherwise silent
        vm.dismissToast()
        vm.restoreDefaultGeneralSelection()
        #expect(vm.banner?.style == .info)
        #expect(!vm.hasRememberedGeneralSelection)
    }

    /// The clean phase is not the developer feature's private business: a
    /// general-module clean has to reach the progress overlay and the result
    /// summary too, or clicking "clean now" there does the work with no
    /// visible feedback at all (the general page's rows say nothing about
    /// progress, and its detail branch used to swallow cleanPhase entirely).
    @Test func cleanPhaseIsNotSwallowedByTheGeneralPage() {
        let vm = makeVM()
        vm.apply(.discovered([
            item("system.logs", "Foo.log", category: .system, risk: .safe, size: 100),
        ]))

        // On the general page, a clean in flight is still a clean in flight
        vm.showGeneralCleanup()
        vm.requestClean()
        #expect(vm.cleanPhase == .confirming)
        vm.beginClean()
        #expect(vm.cleanPhase == .cleaning, "a clean on the general page also enters the cleaning state")
        // …and so is the finished state the result summary reads
        vm.cancelClean()
        #expect(vm.cleanPhase == .idle)
    }
}
