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

    /// Records what the clean closure was called with, so a test can prove
    /// the tool forwards the shared setting rather than assuming it.
    private final class CleanCall: @unchecked Sendable {
        var moveToTrash: Bool?
        var itemCount = 0
    }

    /// A clean stand-in: reports every item as succeeded (or the ones in
    /// `failing` as failed), so the state machine can be driven without
    /// touching the disk. The call's arguments land in `call` when given.
    private func fakeClean(
        failing: Set<String> = [],
        movedToTrash: Bool = false,
        call: CleanCall? = nil
    ) -> (@MainActor @Sendable ([JunkItem], Bool) -> AsyncStream<CleanEvent>) {
        { items, useTrash in
            call?.moveToTrash = useTrash
            call?.itemCount = items.count
            return AsyncStream(CleanEvent.self) { continuation in
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
            scan: { AppUninstallModel.AppScanResult(items: scanned) },
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
            return AppUninstallModel.AppScanResult(items: sampleItems())
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

    /// The same app installed in both `/Applications` and `~/Applications`
    /// is two rows the user can uninstall one at a time; both claim the same
    /// residue files, and because the selection is a set of item ids each
    /// path is still deleted once.
    @Test func groupingKeepsBothCopiesOfTheSameBundleID() {
        let secondCopy = JunkItem(
            ruleID: "app.bundle", title: "Foo", detail: "Version 2.0",
            path: "/Users/x/Applications/Foo.app", category: .apps, risk: .caution, size: 500,
            bundleID: "com.example.foo", appKind: .bundle, holdsLiveAppData: true
        )
        let grouped = AppUninstallModel.group(sampleItems() + [secondCopy])

        #expect(grouped.count == 3, "both copies stay listed, got \(grouped.map(\.bundle.path))")
        let copies = grouped.filter { $0.name == "Foo" }
        #expect(copies.count == 2)
        #expect(copies[0].residues.count == 2 && copies[1].residues.count == 2)
        #expect(Set(copies[0].residues.map(\.id)) == Set(copies[1].residues.map(\.id)),
                "both copies claim the same leftover files")
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

    @Test func beginCleanForwardsTheMoveToTrashSetting() async {
        let call = CleanCall()
        let model = AppUninstallModel(scan: { AppUninstallModel.AppScanResult(items: sampleItems()) }, clean: fakeClean(call: call))
        model.activate()
        await model.waitUntilSettled()
        model.setAppSelected(entry("Bar", in: model), selected: true)
        model.requestUninstall()
        model.beginClean(moveToTrash: true)
        await model.waitUntilSettled()

        #expect(call.moveToTrash == true, "the shared setting is forwarded, not re-decided inside the tool")
        #expect(call.itemCount == 1)
    }

    @Test func aFailedCleanKeepsTheAppAndItsCheck() async {
        let sample = sampleItems()
        // The bundle is refused (a running app); the junk residue goes.
        let bundleID = "app.bundle::/Applications/Foo.app"
        let prefsID = "app.residue::/Users/x/Library/Preferences/com.example.foo.plist"
        let cacheID = "app.junk::/Users/x/Library/Caches/com.example.foo"
        let model = AppUninstallModel(
            scan: { AppUninstallModel.AppScanResult(items: sample) },
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

    @Test func bundleRemovedButResidueFailedLeavesNoDanglingCheck() async {
        let sample = sampleItems()
        let prefsID = "app.residue::/Users/x/Library/Preferences/com.example.foo.plist"
        // The bundle and the cache go; only the preferences file is refused.
        let model = AppUninstallModel(
            scan: { AppUninstallModel.AppScanResult(items: sample) },
            clean: fakeClean(failing: [prefsID])
        )
        model.activate()
        await model.waitUntilSettled()
        model.setAppSelected(entry("Foo", in: model), selected: true)
        model.requestUninstall()
        model.beginClean(moveToTrash: false)
        await model.waitUntilSettled()

        // The app is uninstalled, so its entry leaves the list entirely —
        // listing it would claim it is still installed.
        #expect(model.apps.map(\.name) == ["Bar"])
        // The refused file's check cannot survive as a ghost: nothing in the
        // list matches it any more.
        #expect(!model.selectedIDs.contains(prefsID))
        #expect(model.selectedIDs.isEmpty)
        // The failure is still reported, with its reason, so the user learns
        // the file is still on disk.
        #expect(model.failures == 1)
        #expect(model.outcomes.first { !$0.succeeded }?.itemID == prefsID)
        #expect(model.reclaimed == 600, "bundle 500 + cache 100")
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

    /// A clean stopped half-way keeps what it already removed: the engine
    /// reports completed outcomes before the cancellation lands, and those
    /// entries must leave the list rather than pad it as ghosts.
    @Test func cancelCleanMidRunKeepsWhatAlreadyLeftTheDisk() async {
        let gate = Gate()
        let model = AppUninstallModel(
            scan: { AppUninstallModel.AppScanResult(items: sampleItems()) },
            clean: { items, _ in
                AsyncStream(CleanEvent.self) { continuation in
                    // The blocking wait lives in a detached task: the build
                    // closure itself runs on the caller's thread — the main
                    // actor — so waiting here would deadlock the test.
                    Task.detached {
                        continuation.yield(.started(total: items.count))
                        for item in items {
                            continuation.yield(.outcome(CleanOutcome(
                                id: item.id, itemID: item.id, title: item.title, path: item.path,
                                reclaimed: item.size, succeeded: true, message: "done"
                            )))
                        }
                        // Hold the finish back: the cancel lands with every
                        // outcome already reported but the clean not yet
                        // wrapped up, which is the state a long-running clean
                        // is in when the user presses Stop.
                        gate.wait()
                        continuation.yield(.finished(reclaimed: 0, failures: 0))
                        continuation.finish()
                    }
                }
            }
        )
        model.activate()
        await model.waitUntilSettled()
        model.setAppSelected(entry("Foo", in: model), selected: true)
        model.requestUninstall()
        model.beginClean(moveToTrash: false)
        await waitUntilOutcomes(3, in: model)

        model.cancelClean()

        #expect(model.phase == .idle)
        #expect(model.apps.map(\.name) == ["Bar"], "the uninstalled app left the list even though the clean was stopped")
        #expect(model.selectedIDs.isEmpty, "the removed items' checks went with them")
        #expect(model.outcomes.isEmpty, "a cancelled clean reports no result")

        // Let the held-back stream finish so no thread is left blocked.
        gate.open()
    }

    /// Polls until the clean has reported the given number of outcomes. The
    /// model's `waitUntilSettled` cannot be used here: the stream is held
    /// open on purpose, so the clean never settles on its own.
    private func waitUntilOutcomes(_ count: Int, in model: AppUninstallModel) async {
        for _ in 0..<500 {
            if model.outcomes.count >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A gate a stream can block on until the test opens it.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func wait() { semaphore.wait() }
        func open() { semaphore.signal() }
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

    @Test func selectResiduesForSelectedAppsKeepsUnrelatedSelections() async {
        let model = makeModel()
        model.activate()
        await model.waitUntilSettled()
        let foo = entry("Foo", in: model)
        let bar = entry("Bar", in: model)
        model.setAppSelected(bar, selected: true)
        model.setAppSelected(foo, selected: true)
        model.setResidueSelected(foo.residues[0], selected: false)

        model.selectResiduesForSelectedApps()

        #expect(model.selectedIDs.contains(bar.bundle.id), "an unrelated app's check is not disturbed")
        #expect(model.selectionState(of: foo) == .all)
        #expect(model.unselectedResidues.isEmpty)
    }

    // MARK: - Rescan

    @Test func rescanDropsVanishedAppsFromTheSelection() async {
        // A box rather than a captured var: the scan closure reads it on
        // every call, so the test can change what the "disk" holds between
        // scans without mutating a captured local.
        let disk = ScanBox(sampleItems())
        let model = AppUninstallModel(scan: { AppUninstallModel.AppScanResult(items: disk.items) })
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
            scan: { AppUninstallModel.AppScanResult(items: []) },
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

    /// The cache is capped. The uninstall list has no upper bound on how many
    /// apps a machine has installed, and every cached NSImage carries its full
    /// representation set — an unbounded cache is one NSImage per installed app
    /// held for the whole session, for the life of the process.
    @Test func theIconCacheEvictsSoItCannotGrowWithoutBound() {
        var calls = 0
        let model = AppUninstallModel(
            scan: { AppUninstallModel.AppScanResult(items: []) },
            iconForPath: { _ in
                calls += 1
                return NSImage()
            }
        )

        // Far past any sane cache: the rows a user scrolls through.
        for index in 0..<400 {
            _ = model.icon(forPath: "/Applications/App\(index).app")
        }
        let afterFilling = calls
        #expect(afterFilling == 400, "each distinct path is looked up once")

        // The first paths were evicted, so asking for them again costs a lookup
        // — the cache cannot have kept all 400.
        _ = model.icon(forPath: "/Applications/App0.app")
        _ = model.icon(forPath: "/Applications/App1.app")
        #expect(calls > afterFilling, "an evicted icon was served from the cache")
    }

    /// A path with no icon must not take a cache slot. `iconCache[path] = nil`
    /// removes the key rather than storing a nil, so such a path is never
    /// cached — appending it to the eviction order anyway would evict a real
    /// icon on every render and re-run the lookup for a path that will never
    /// have one.
    @Test func aPathWithNoIconDoesNotTakeACacheSlot() {
        var calls = 0
        let model = AppUninstallModel(
            scan: { AppUninstallModel.AppScanResult(items: []) },
            iconForPath: { path in
                calls += 1
                return path == "/Applications/NoIcon.app" ? nil : NSImage()
            }
        )

        // Fill well past the cache, so the oldest entries have already been
        // evicted, then ask for one path that has no icon at all.
        for index in 0..<200 {
            _ = model.icon(forPath: "/Applications/App\(index).app")
        }
        _ = model.icon(forPath: "/Applications/NoIcon.app")

        // The oldest surviving entry must still be cached: a path with no icon
        // cannot have pushed it out.
        let before = calls
        _ = model.icon(forPath: "/Applications/App72.app")
        #expect(calls == before, "a path with no icon evicted a real icon from the cache")
    }

    // MARK: - End to end against real files

    /// Creates a fake .app plus a cache and a preferences file, mirroring the
    /// app scanner tests' fixture helpers. Cleans up after itself even when a
    /// write halfway through throws, so a failed setup leaves nothing behind;
    /// the caller owns the directories once this returns.
    private func makeFixture(label: String) throws -> (apps: URL, home: URL, appPath: String, prefsPath: String, cachePath: String) {
        func canonicalDirectory(_ suffix: String) throws -> URL {
            let raw = FileManager.default.temporaryDirectory
                .appendingPathComponent("mackit-uninstall-\(label)-\(suffix)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            return URL(fileURLWithPath: FileSystem.canonical(raw.path))
        }
        let apps = try canonicalDirectory("apps")
        let home = try canonicalDirectory("home")
        do {
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
        } catch {
            // A throw halfway through would otherwise leak both directories
            // for the life of the test process.
            try? FileManager.default.removeItem(at: apps)
            try? FileManager.default.removeItem(at: home)
            throw error
        }
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
                    let measured = await ScanEngine.measure(discovered)
                    return AppUninstallModel.AppScanResult(items: measured)
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
                    return AppUninstallModel.AppScanResult(items: await ScanEngine.measure(discovered))
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
