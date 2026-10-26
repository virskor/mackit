import Foundation
import AppKit
import Testing

@testable import Mackit

/// Tests for the app uninstall tool's state model.
///
/// The model is driven through its injected closures: a fixture item list
/// stands in for the scan, a recording clean for the engine, so nothing here
/// touches the real /Applications or ~/Library — except the two end-to-end
/// tests at the bottom, which build fake apps on disk and run the real
/// `CleanEngine`, the same way the app scanner's own tests do.
@MainActor
struct AppUninstallModelTests {
    /// One app (Foo) with a regenerable cache and a data residue (its
    /// preferences), plus one app (Bar) with no residue at all.
    private func sampleItems() -> [JunkItem] {
        let app = JunkItem(
            ruleID: "app.bundle", title: "Foo", detail: "Version 2.0 · 2 leftover files",
            path: "/Applications/Foo.app", category: .apps, risk: .caution, size: 500,
            bundleID: "com.example.foo", appKind: .bundle, holdsLiveAppData: true,
            searchExtra: "com.example.foo"
        )
        let cache = JunkItem(
            ruleID: "app.junk", title: "com.example.foo", detail: "Foo's cache",
            path: "/Users/x/Library/Caches/com.example.foo", category: .appJunk, risk: .safe, size: 100,
            bundleID: "com.example.foo", appKind: .residue(.caches), appName: "Foo"
        )
        let prefs = JunkItem(
            ruleID: "app.residue", title: "com.example.foo.plist", detail: "Foo's preferences",
            path: "/Users/x/Library/Preferences/com.example.foo.plist", category: .apps, risk: .review, size: 50,
            bundleID: "com.example.foo", appKind: .residue(.preferences), appName: "Foo",
            holdsLiveAppData: true
        )
        let bar = JunkItem(
            ruleID: "app.bundle", title: "Bar", detail: "Version 1.0",
            path: "/Applications/Bar.app", category: .apps, risk: .caution, size: 200,
            bundleID: "com.example.bar", appKind: .bundle, holdsLiveAppData: true,
            searchExtra: "com.example.bar"
        )
        return [app, cache, prefs, bar]
    }

    /// A clean stand-in: reports every item as succeeded (or the ones in
    /// `failing` as failed), so the state machine can be driven without
    /// touching the disk.
    private func fakeClean(
        failing: Set<String> = [],
        movedToTrash: Bool = false
    ) -> (@MainActor @Sendable ([JunkItem], Bool) -> AsyncStream<CleanEvent>) {
        { items, _ in
            AsyncStream(CleanEvent.self) { continuation in
                continuation.yield(.started(total: items.count))
                var reclaimed: Int64 = 0
                var failures = 0
                for item in items {
                    let succeeded = !failing.contains(item.id)
                    if succeeded {
                        reclaimed += item.size
                    } else {
                        failures += 1
                    }
                    continuation.yield(.outcome(CleanOutcome(
                        id: item.id, itemID: item.id, title: item.title, path: item.path,
                        reclaimed: succeeded ? item.size : 0, succeeded: succeeded,
                        message: succeeded ? "done" : "refused",
                        movedToTrash: succeeded && movedToTrash
                    )))
                }
                continuation.yield(.finished(reclaimed: reclaimed, failures: failures))
                continuation.finish()
            }
        }
    }

    private func makeModel(
        items: [JunkItem]? = nil,
        clean: (@MainActor @Sendable ([JunkItem], Bool) -> AsyncStream<CleanEvent>)? = nil,
        isAppRunning: @escaping @MainActor @Sendable (String) -> Bool = { _ in false }
    ) -> AppUninstallModel {
        let scanned = items ?? sampleItems()
        return AppUninstallModel(
            scan: { scanned },
            clean: clean ?? fakeClean(),
            isAppRunning: isAppRunning
        )
    }

    private func entry(_ name: String, in model: AppUninstallModel) -> AppUninstallModel.AppEntry {
        model.apps.first { $0.name == name }!
    }

    // MARK: - Lifecycle

    @Test func firstEntryScansOnceAndRescanRepeats() async {
        var scans = 0
        let model = AppUninstallModel(scan: {
            scans += 1
            return sampleItems()
        })

        model.activate()
        await model.waitUntilSettled()
        #expect(scans == 1)
        #expect(model.hasScanned)
        #expect(model.apps.count == 2, "Foo and Bar")

        // Leaving and coming back must not re-scan — the list belongs to the
        // session, not to the page being visible.
        model.activate()
        await model.waitUntilSettled()
        #expect(scans == 1)

        model.rescan()
        await model.waitUntilSettled()
        #expect(scans == 2)
    }

    @Test func groupingAttachesResiduesToTheirAppLargestFirst() {
        let grouped = AppUninstallModel.group(sampleItems())
        #expect(grouped.map(\.name) == ["Bar", "Foo"], "sorted by name")
        let foo = grouped.first { $0.name == "Foo" }!
        #expect(foo.residues.count == 2)
        #expect(foo.residues[0].size >= foo.residues[1].size, "largest residue first")
        #expect(foo.totalSize == 500 + 100 + 50)
        #expect(foo.allIDs.count == 3)
        let bar = grouped.first { $0.name == "Bar" }!
        #expect(bar.residues.isEmpty)
        #expect(bar.totalSize == 200)
    }

    @Test func residueWithoutItsBundleIsLeftOut() {
        let orphan = JunkItem(
            ruleID: "app.residue", title: "com.example.gone.plist", detail: "",
            path: "/Users/x/Library/Preferences/com.example.gone.plist", category: .apps, risk: .review,
            bundleID: "com.example.gone", appKind: .residue(.preferences), appName: "Gone"
        )
        let grouped = AppUninstallModel.group(sampleItems() + [orphan])
        #expect(!grouped.contains { $0.name == "Gone" })
        #expect(grouped.count == 2)
    }

    // MARK: - Selection

    @Test func appCheckboxIsTriStateOverBundleAndResidues() async {
        let model = makeModel()
        model.activate()
        await model.waitUntilSettled()
        let foo = entry("Foo", in: model)

        #expect(model.selectionState(of: foo) == .none)

        model.setAppSelected(foo, selected: true)
        #expect(model.selectionState(of: foo) == .all)
        #expect(model.selectedItems.count == 3, "bundle + cache + preferences")

        // One residue off reads as partial; checking the app again tops it
        // back up rather than clearing it.
        model.setResidueSelected(foo.residues[1], selected: false)
        #expect(model.selectionState(of: foo) == .partial)
        model.setAppSelected(foo, selected: true)
        #expect(model.selectionState(of: foo) == .all)

        model.setAppSelected(foo, selected: false)
        #expect(model.selectionState(of: foo) == .none)
        #expect(model.selectedItems.isEmpty)
    }

    @Test func contextMenuActionsReplaceTheWholeSelection() async {
        let model = makeModel()
        model.activate()
        await model.waitUntilSettled()
        let foo = entry("Foo", in: model)
        let bar = entry("Bar", in: model)

        model.setAppSelected(bar, selected: true)
        model.selectApp(foo)
        #expect(model.selectedItems.map(\.title) == ["Foo", "com.example.foo", "com.example.foo.plist"],
                "the app's own items, nothing else")

        model.selectAppResidues(foo)
        #expect(model.selectedItems.map(\.title) == ["com.example.foo", "com.example.foo.plist"],
                "residue only, the bundle itself excluded")

        // An app with no residue has nothing to select: the gesture leaves
        // the current selection alone rather than clearing it.
        model.selectAppResidues(bar)
        #expect(model.selectedItems.map(\.title) == ["com.example.foo", "com.example.foo.plist"],
                "an app with no leftovers leaves the selection untouched")
    }

    @Test func searchFiltersTheVisibleApps() async {
        let model = makeModel()
        model.activate()
        await model.waitUntilSettled()
        #expect(model.visibleApps.count == 2)

        model.searchText = "com.example.bar"
        #expect(model.visibleApps.map(\.name) == ["Bar"], "the bundle ID is searchable")

        model.searchText = "nothing matches this"
        #expect(model.visibleApps.isEmpty)
    }

    // MARK: - Uninstall flow

    @Test func requestUninstallNeedsASelectionAndCanBeCancelled() async {
        let model = makeModel()
        model.activate()
        await model.waitUntilSettled()

        model.requestUninstall()
        #expect(model.phase == .idle, "nothing selected: the sheet must not open")

        model.setAppSelected(entry("Foo", in: model), selected: true)
        model.requestUninstall()
        #expect(model.phase == .confirming)
        #expect(model.outcomes.isEmpty, "confirming must not start the clean")

        model.cancelConfirmation()
        #expect(model.phase == .idle)

        // Requesting again after a cancel still works.
        model.requestUninstall()
        #expect(model.phase == .confirming)
    }

    @Test func beginCleanRunsOverTheSelectionAndReportsTheResult() async {
        let model = makeModel(clean: fakeClean(movedToTrash: true))
        model.activate()
        await model.waitUntilSettled()
        let foo = entry("Foo", in: model)

        model.setAppSelected(foo, selected: true)
        model.requestUninstall()
        model.beginClean(moveToTrash: true)
        await model.waitUntilSettled()

        #expect(model.phase == .done)
        #expect(model.reclaimed == 650, "500 + 100 + 50")
        #expect(model.failures == 0)
        #expect(model.movedToTrash, "a recycled clean must not claim the bytes are back")
        #expect(model.outcomes.count == 3)
        // The uninstalled app leaves the list; the untouched one stays.
        #expect(model.apps.map(\.name) == ["Bar"])
        #expect(model.selectedIDs.isEmpty, "the cleaned items' checks are dropped")

        model.dismissResult()
        #expect(model.phase == .idle)
    }

    @Test func aFailedCleanKeepsTheAppAndItsCheck() async {
        let sample = sampleItems()
        // The bundle is refused (a running app); the junk residue goes.
        let bundleID = "app.bundle::/Applications/Foo.app"
        let prefsID = "app.residue::/Users/x/Library/Preferences/com.example.foo.plist"
        let cacheID = "app.junk::/Users/x/Library/Caches/com.example.foo"
        let model = AppUninstallModel(
            scan: { sample },
            clean: fakeClean(failing: [bundleID, prefsID])
        )
        model.activate()
        await model.waitUntilSettled()
        let foo = entry("Foo", in: model)
        model.setAppSelected(foo, selected: true)
        model.requestUninstall()
        model.beginClean(moveToTrash: false)
        await model.waitUntilSettled()

        #expect(model.phase == .done)
        #expect(model.failures == 2)
        #expect(model.reclaimed == 100, "only the cache was removed")
        // The app is still listed — the preferences file it kept, because
        // that is the residue whose clean was refused.
        let remaining = entry("Foo", in: model)
        #expect(remaining.residues.map(\.title) == ["com.example.foo.plist"])
        // The failed items stay checked so they can be retried.
        #expect(model.selectedIDs.contains(remaining.bundle.id))
        #expect(model.selectedIDs.contains(remaining.residues[0].id))
        // The cleaned residue's check is gone.
        #expect(!model.selectedIDs.contains(cacheID))
    }

    @Test func beginCleanOutsideConfirmationIsIgnored() async {
        let model = makeModel()
        model.activate()
        await model.waitUntilSettled()
        model.setAppSelected(entry("Foo", in: model), selected: true)

        model.beginClean(moveToTrash: false)
        #expect(model.phase == .idle, "the clean only runs from the confirmation sheet")
    }

    @Test func cancelCleanReturnsToIdleAndKeepsRemovedItems() async {
        let model = makeModel()
        model.activate()
        await model.waitUntilSettled()
        model.setAppSelected(entry("Foo", in: model), selected: true)
        model.requestUninstall()
        model.beginClean(moveToTrash: false)
        model.cancelClean()
        #expect(model.phase == .idle)

        // A cancel after the result is up must not throw the result away.
        model.requestUninstall()
        model.beginClean(moveToTrash: false)
        await model.waitUntilSettled()
        #expect(model.phase == .done)
        model.cancelClean()
        #expect(model.phase == .done)
    }

    // MARK: - Confirmation sheet data

    @Test func runningAppsAreListedForTheConfirmation() async {
        let model = makeModel(isAppRunning: { $0 == "com.example.foo" })
        model.activate()
        await model.waitUntilSettled()
        model.setAppSelected(entry("Foo", in: model), selected: true)

        #expect(model.runningAppNames == ["Foo"])
        #expect(model.selectedAppCount == 1, "the count is apps, not files")
    }

    @Test func unselectedResiduesSummarizePendingFilesPerApp() async {
        let model = makeModel()
        model.activate()
        await model.waitUntilSettled()
        let foo = entry("Foo", in: model)

        // Only the bundle checked: both residue files count as leftovers.
        model.setAppSelected(foo, selected: true)
        model.setResidueSelected(foo.residues[0], selected: false)
        model.setResidueSelected(foo.residues[1], selected: false)

        let pending = model.unselectedResidues
        #expect(pending.count == 1)
        #expect(pending[0].appName == "Foo")
        #expect(pending[0].count == 2)
        #expect(pending[0].size == 150)

        // The one-click catch-up checks every leftover of every checked app.
        model.selectResiduesForSelectedApps()
        #expect(model.unselectedResidues.isEmpty)
        #expect(model.selectionState(of: foo) == .all)
    }

    // MARK: - Rescan

    @Test func rescanDropsVanishedAppsFromTheSelection() async {
        // A box rather than a captured var: the scan closure reads it on
        // every call, so the test can change what the "disk" holds between
        // scans without mutating a captured local.
        let disk = ScanBox(sampleItems())
        let model = AppUninstallModel(scan: { disk.items })
        model.activate()
        await model.waitUntilSettled()
        model.setAppSelected(entry("Foo", in: model), selected: true)
        model.setAppSelected(entry("Bar", in: model), selected: true)

        // Foo was uninstalled elsewhere; the fresh scan no longer lists it.
        disk.items = [sampleItems()[3]]
        model.rescan()
        await model.waitUntilSettled()

        #expect(model.apps.map(\.name) == ["Bar"])
        #expect(model.selectedIDs == Set([entry("Bar", in: model).bundle.id]),
                "the vanished app's check cannot survive as a ghost")
    }

    /// A mutable scan fixture: what the "disk" currently holds.
    private final class ScanBox: @unchecked Sendable {
        var items: [JunkItem]
        init(_ items: [JunkItem]) { self.items = items }
    }

    // MARK: - Icons

    @Test func iconIsCachedPerPath() {
        var calls = 0
        let model = AppUninstallModel(
            scan: { [] },
            iconForPath: { _ in
                calls += 1
                return NSImage()
            }
        )
        _ = model.icon(forPath: "/Applications/Foo.app")
        _ = model.icon(forPath: "/Applications/Foo.app")
        _ = model.icon(forPath: "/Applications/Bar.app")
        #expect(calls == 2, "one lookup per distinct path")
        #expect(model.icon(forPath: "") == nil, "an empty path has no icon")
    }

    // MARK: - End to end against real files

    /// Creates a fake .app plus a cache and a preferences file, mirroring the
    /// app scanner tests' fixture helpers.
    private func makeFixture(label: String) throws -> (apps: URL, home: URL, appPath: String, prefsPath: String, cachePath: String) {
        func canonicalDirectory(_ suffix: String) throws -> URL {
            let raw = FileManager.default.temporaryDirectory
                .appendingPathComponent("mackit-uninstall-\(label)-\(suffix)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            return URL(fileURLWithPath: FileSystem.canonical(raw.path))
        }
        let apps = try canonicalDirectory("apps")
        let home = try canonicalDirectory("home")

        let contents = apps.appendingPathComponent("Foo.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.foo",
            "CFBundleName": "Foo",
            "CFBundleShortVersionString": "3.1"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let prefs = home.appendingPathComponent("Library/Preferences/com.example.foo.plist")
        try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("prefs".utf8).write(to: prefs)
        let cache = home.appendingPathComponent("Library/Caches/com.example.foo")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("cache-bytes".utf8).write(to: cache.appendingPathComponent("cache.bin"))

        return (apps, home, contents.deletingLastPathComponent().path, prefs.path, cache.path)
    }

    @Test func uninstallRemovesTheAppAndItsFilesFromDisk() async throws {
        let fixture = try makeFixture(label: "e2e")
        defer {
            try? FileManager.default.removeItem(at: fixture.apps)
            try? FileManager.default.removeItem(at: fixture.home)
        }

        let model = AppUninstallModel(
            scan: {
                await Task.detached(priority: .utility) {
                    let discovered = AppScanner.scanApps(roots: [fixture.apps.path], home: fixture.home.path)
                    return await ScanEngine.measure(discovered)
                }.value
            },
            clean: { items, moveToTrash in
                CleanEngine.clean(items: items, moveToTrash: moveToTrash, isAppRunning: { _ in false })
            }
        )
        model.activate()
        await model.waitUntilSettled()
        #expect(model.apps.count == 1)
        #expect(model.apps[0].residues.count == 2, "cache + preferences")

        model.setAppSelected(model.apps[0], selected: true)
        model.requestUninstall()
        model.beginClean(moveToTrash: false)
        await model.waitUntilSettled()

        #expect(model.phase == .done)
        #expect(model.failures == 0)
        #expect(model.reclaimed > 0)
        #expect(model.apps.isEmpty, "the uninstalled app leaves the list")
        #expect(!FileManager.default.fileExists(atPath: fixture.appPath), "the bundle is gone")
        #expect(!FileManager.default.fileExists(atPath: fixture.prefsPath), "the preferences are gone")
        #expect(!FileManager.default.fileExists(atPath: fixture.cachePath), "the cache is gone")
    }

    @Test func runningAppIsRefusedAndStaysInTheList() async throws {
        let fixture = try makeFixture(label: "running")
        defer {
            try? FileManager.default.removeItem(at: fixture.apps)
            try? FileManager.default.removeItem(at: fixture.home)
        }

        let model = AppUninstallModel(
            scan: {
                await Task.detached(priority: .utility) {
                    let discovered = AppScanner.scanApps(roots: [fixture.apps.path], home: fixture.home.path)
                    return await ScanEngine.measure(discovered)
                }.value
            },
            clean: { items, moveToTrash in
                CleanEngine.clean(items: items, moveToTrash: moveToTrash, isAppRunning: { $0 == "com.example.foo" })
            },
            // The model's own check, which the confirmation sheet reads —
            // the same answer the clean engine is given below.
            isAppRunning: { $0 == "com.example.foo" }
        )
        model.activate()
        await model.waitUntilSettled()
        model.setAppSelected(model.apps[0], selected: true)
        #expect(model.runningAppNames == ["Foo"], "the confirmation lists it in advance")

        model.requestUninstall()
        model.beginClean(moveToTrash: false)
        await model.waitUntilSettled()

        // The bundle and the preferences hold live data and are refused; the
        // cache is regenerable and goes.
        #expect(model.failures == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.appPath), "the running app's bundle must survive")
        #expect(FileManager.default.fileExists(atPath: fixture.prefsPath), "the running app's preferences must survive")
        #expect(!FileManager.default.fileExists(atPath: fixture.cachePath), "the cache is rebuilt on demand")
        #expect(model.apps.count == 1, "the refused app stays in the list")
        #expect(entry("Foo", in: model).residues.count == 1, "only the cache left the entry")
    }
}
