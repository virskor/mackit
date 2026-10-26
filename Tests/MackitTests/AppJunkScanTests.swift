import Foundation
import Testing

@testable import Mackit

/// Tests for the cleanup scan's app-junk phase.
///
/// The general module's app-junk row is fed by a junk-only scan: the
/// regenerable leftovers (caches, HTTP storages, WebKit data, logs, crash
/// reports) roll up there, while the apps themselves and their data residue
/// belong to the app uninstall tool and must never enter the cleanup scan —
/// otherwise "clean everything" could reach app data the user only meant to
/// sweep caches for.
@MainActor
struct AppJunkScanTests {
    /// Creates a fake .app with a regenerable cache and a data residue (its
    /// preferences), the split `AppScanner` makes.
    private func makeFixture(label: String) throws -> (apps: URL, home: URL, cachePath: String) {
        func canonicalDirectory(_ suffix: String) throws -> URL {
            let raw = FileManager.default.temporaryDirectory
                .appendingPathComponent("mackit-appjunk-\(label)-\(suffix)-\(UUID().uuidString)")
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

        let cache = home.appendingPathComponent("Library/Caches/com.example.foo")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        // An empty directory has size 0; a file must be placed in it to
        // verify size measurement and the default pre-check
        try Data("cache-bytes".utf8).write(to: cache.appendingPathComponent("cache.bin"))
        let prefs = home.appendingPathComponent("Library/Preferences/com.example.foo.plist")
        try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("prefs".utf8).write(to: prefs)

        return (apps, home, cache.path)
    }

    @Test func scanAppJunkMergesOnlyJunkIntoTheList() async throws {
        let fixture = try makeFixture(label: "scan")
        defer {
            try? FileManager.default.removeItem(at: fixture.apps)
            try? FileManager.default.removeItem(at: fixture.home)
        }

        let vm = AppViewModel(statsPolling: false)
        await vm.scanAppJunk(roots: [fixture.apps.path], home: fixture.home.path)

        #expect(vm.progressLabel == L10n.tr("scan.apps"))
        #expect(vm.items.count == 1, "only the regenerable cache is a cleanup item, got \(vm.items.map(\.path))")
        let item = vm.items[0]
        #expect(item.category == .appJunk)
        #expect(item.ruleID == AppScanner.junkRuleID)
        #expect(item.appName == "Foo")
        #expect(item.size > 0, "size should be filled in after the scan")
        #expect(vm.categoryCounts[.apps, default: 0] == 0, "app bundles are not part of the cleanup scan")
        #expect(vm.categoryCounts[.appJunk] == 1)
    }

    @Test func appJunkLandsOnTheGeneralPageRowPreChecked() async throws {
        let fixture = try makeFixture(label: "row")
        defer {
            try? FileManager.default.removeItem(at: fixture.apps)
            try? FileManager.default.removeItem(at: fixture.home)
        }

        let vm = AppViewModel(statsPolling: false)
        await vm.scanAppJunk(roots: [fixture.apps.path], home: fixture.home.path)

        let group = vm.generalCleanGroups.first { $0.group == .appJunk }!
        let row = group.rows.first { $0.row.id == "app.junk" }!
        #expect(row.items.count == 1)
        #expect(row.size > 0)
        // Safe rows arrive pre-checked, so the junk joins the default sweep.
        #expect(row.selectedCount == 1)
        #expect(vm.selection.contains(vm.items[0].id))
        // The row groups its entries per app, titled with the app's name.
        #expect(row.subRows.count == 1)
        #expect(row.subRows[0].title == "Foo")
        #expect(row.subRows[0].isFullySelected)
    }
}
