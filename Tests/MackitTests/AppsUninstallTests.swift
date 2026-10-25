import Foundation
import Testing

@testable import Mackit

/// Tests for app uninstall selection actions and list merging.
///
/// All items are constructed in memory, never touching the real file system;
/// scan actions are injected via `vm.apply(.discovered:)`, the same driving
/// approach as the menu bar tests.
@MainActor
struct AppsUninstallTests {
    /// One app (Foo) + one junk residue (its cache) + one data residue (its
    /// preferences) + one unrelated Xcode cache. The junk residue belongs to
    /// the general module's app-junk row, the data residue to the uninstall
    /// flow — see `AppScanner.items(for:)`.
    private func sampleItems() -> [JunkItem] {
        let app = JunkItem(
            ruleID: "app.bundle", title: "Foo", detail: "Version 2.0 · 2 leftover files",
            path: "/Applications/Foo.app", category: .apps, risk: .caution,
            bundleID: "com.example.foo", appKind: .bundle, holdsLiveAppData: true,
            searchExtra: "com.example.foo"
        )
        let cache = JunkItem(
            ruleID: "app.junk", title: "com.example.foo", detail: "Foo's cache",
            path: "/Users/x/Library/Caches/com.example.foo", category: .appJunk, risk: .safe,
            bundleID: "com.example.foo", appKind: .residue(.caches), appName: "Foo"
        )
        let prefs = JunkItem(
            ruleID: "app.residue", title: "com.example.foo.plist", detail: "Foo's preferences",
            path: "/Users/x/Library/Preferences/com.example.foo.plist", category: .apps, risk: .review,
            bundleID: "com.example.foo", appKind: .residue(.preferences), appName: "Foo",
            holdsLiveAppData: true
        )
        let derived = JunkItem(
            ruleID: "xcode.deriveddata", title: "DerivedData", detail: "Xcode",
            path: "/Users/x/Library/Developer/Xcode/DerivedData", category: .xcode, risk: .safe
        )
        return [app, cache, prefs, derived]
    }

    private func appItem(in vm: AppViewModel) -> JunkItem {
        vm.items.first { $0.appKind == .bundle }!
    }

    /// Simulates the user checking rows in the table: each row that differs
    /// from the target set is clicked once.
    private func select(_ ids: Set<String>, in vm: AppViewModel) {
        for item in vm.items where vm.selection.contains(item.id) != ids.contains(item.id) {
            vm.toggle(item)
        }
    }

    private func residueItems(in vm: AppViewModel) -> [JunkItem] {
        vm.items.filter { $0.appKind?.isResidue == true }
    }

    @Test func uninstallSelectsAppAndResidues() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))
        let app = appItem(in: vm)

        vm.uninstallApp(app)

        #expect(vm.cleanPhase == .confirming)
        #expect(vm.selection.count == 3, "app + two leftovers")
        #expect(vm.selection.contains(app.id))
        #expect(vm.hasSelectedApps)
        // Items from unrelated categories are not pulled in
        #expect(!vm.selection.contains("xcode.deriveddata::/Users/x/Library/Developer/Xcode/DerivedData"))
    }

    @Test func selectResiduesOnlyExcludesApp() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))
        let app = appItem(in: vm)

        vm.selectAppResidues(app)

        #expect(vm.cleanPhase == .confirming)
        #expect(vm.selection.count == 2)
        #expect(!vm.selection.contains(app.id))
        #expect(!vm.hasSelectedApps)
    }

    @Test func residueActionsIgnoreNonBundleItems() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))
        let residue = vm.items.first { $0.appKind?.isResidue == true }!

        vm.uninstallApp(residue)
        vm.selectAppResidues(residue)

        #expect(vm.selection.isEmpty)
        #expect(vm.cleanPhase == .idle)
    }

    @Test func selectAppResiduesWithoutResiduesDoesNothing() {
        let vm = AppViewModel(statsPolling: false)
        let app = JunkItem(
            ruleID: "app.bundle", title: "Bar", detail: "",
            path: "/Applications/Bar.app", category: .apps, risk: .caution,
            bundleID: "com.example.bar", appKind: .bundle
        )
        vm.apply(.discovered([app]))

        vm.selectAppResidues(app)

        #expect(vm.selection.isEmpty, "should not enter confirmation when there are no leftovers to clean")
        #expect(vm.cleanPhase == .idle)
    }

    @Test func residueIDsMatchByBundleID() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))
        #expect(vm.residueIDs(for: appItem(in: vm)).count == 2)
    }

    @Test func appItemsCarryCategoryRiskAndSearchText() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))
        let app = appItem(in: vm)

        #expect(app.category == .apps)
        #expect(app.risk == .caution)
        #expect(app.searchBlob.contains("com.example.foo"))
        #expect(app.id == "app.bundle::/Applications/Foo.app")
        // The uninstall category counts the bundle and the data residue; the
        // cache belongs to the general module's app-junk row instead
        #expect(vm.categoryCounts[.apps] == 2)
        #expect(vm.categoryCounts[.appJunk] == 1)
        #expect(vm.categoryTotals[.apps] == 0, "in-memory items have no measured size")
    }

    @Test func runningAppNamesExcludesNonRunningApps() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))
        vm.uninstallApp(appItem(in: vm))
        // com.example.foo cannot possibly be running
        #expect(vm.runningAppNames.isEmpty)
    }

    @Test func mergeDiscoveredDeduplicatesByID() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))

        vm.mergeDiscovered(sampleItems())
        #expect(vm.items.count == 4, "a duplicate batch should not add items")

        let extra = JunkItem(
            ruleID: "app.residue", title: "com.example.foo", detail: "Foo's logs",
            path: "/Users/x/Library/Logs/com.example.foo", category: .apps, risk: .safe,
            bundleID: "com.example.foo", appKind: .residue(.logs)
        )
        vm.mergeDiscovered([extra])
        #expect(vm.items.count == 5, "a new item should merge normally")
    }

    @Test func iconIsOnlyProvidedForAppBundles() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))
        let residue = vm.items.first { $0.appKind?.isResidue == true }!
        #expect(vm.icon(for: residue) == nil)
    }

    @Test func unselectedResiduesSummarizesPendingFilesPerApp() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))

        // Only the app bundle checked: both associated files count as
        // leftovers
        select([appItem(in: vm).id], in: vm)
        let pending = vm.unselectedAppResidues
        #expect(pending.count == 1)
        #expect(pending[0].appName == "Foo")
        #expect(pending[0].count == 2)

        // With one more checked, only one remains
        select([appItem(in: vm).id, residueItems(in: vm)[0].id], in: vm)
        #expect(vm.unselectedAppResidues.first?.count == 1)
    }

    @Test func selectResiduesForSelectedAppsChecksPendingResidues() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))
        let app = appItem(in: vm)
        select([app.id], in: vm)

        vm.selectResiduesForSelectedApps()

        #expect(vm.selection.count == 3, "app + two associated files")
        #expect(vm.unselectedAppResidues.isEmpty)
        #expect(vm.cleanPhase == .idle, "topping up the selection should not directly show the confirmation panel")
    }

    @Test func selectResiduesForSelectedAppsKeepsUnrelatedSelections() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))
        let unrelated = vm.items.first { $0.category == .xcode }!
        select([appItem(in: vm).id, unrelated.id], in: vm)

        vm.selectResiduesForSelectedApps()

        #expect(vm.selection.contains(unrelated.id), "unrelated items should stay checked")
        #expect(vm.selection.count == 4)
    }

    @Test func noLeftoverSummaryWhenEverythingIsSelected() {
        let vm = AppViewModel(statsPolling: false)
        vm.apply(.discovered(sampleItems()))
        vm.uninstallApp(appItem(in: vm))
        #expect(vm.unselectedAppResidues.isEmpty)

        // Checking only the associated files but not the app bundle does not
        // count as a leftover either
        let vm2 = AppViewModel(statsPolling: false)
        vm2.apply(.discovered(sampleItems()))
        select(Set(residueItems(in: vm2).map(\.id)), in: vm2)
        #expect(vm2.unselectedAppResidues.isEmpty)
    }

    @Test func scanAppsMergesIntoList() async throws {
        // Subpaths returned by FileManager have symlinks resolved
        // (/var → /private/var); the temporary directory must be normalized
        // before comparing with the probed paths. The app's own
        // canonicalizer keeps the spelling identical to the scanner's.
        func canonicalDirectory(_ label: String) throws -> URL {
            let raw = FileManager.default.temporaryDirectory
                .appendingPathComponent("mackit-vm-\(label)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            return URL(fileURLWithPath: FileSystem.canonical(raw.path))
        }

        let appsDir = try canonicalDirectory("apps")
        let home = try canonicalDirectory("home")
        defer {
            try? FileManager.default.removeItem(at: appsDir)
            try? FileManager.default.removeItem(at: home)
        }

        let contents = appsDir.appendingPathComponent("Foo.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.foo",
            "CFBundleName": "Foo",
            "CFBundleShortVersionString": "3.1"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let cacheDir = home.appendingPathComponent("Library/Caches/com.example.foo")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // An empty directory has size 0; a file must be placed in it to
        // verify size measurement
        try Data("cache-bytes".utf8).write(to: cacheDir.appendingPathComponent("cache.bin"))

        let vm = AppViewModel(statsPolling: false)
        await vm.scanApps(roots: [appsDir.path], home: home.path)

        #expect(vm.progressLabel == L10n.tr("scan.apps"))
        #expect(vm.items.count == 2, "1 bundle + 1 cache leftover")
        #expect(vm.items.contains { $0.appKind == .bundle })
        #expect(vm.items.contains { $0.appKind?.isResidue == true })
        // Size has been measured: the cache directory is non-empty
        let residue = vm.items.first { $0.appKind?.isResidue == true }!
        #expect(residue.size > 0, "size should be filled in after the scan")
    }
}
