import Foundation
import Testing

@testable import Mackit

/// Tests for the leftover-cache pool.
///
/// The fixture is one installed fake app plus a home directory whose cache
/// trees hold claimed, protected, self-owned and unclaimed entries — nothing
/// here touches the real ~/Library.
struct LeftoverCacheScannerTests {
    /// Builds the fixture: an installed `Foo` app (com.example.foo) and a
    /// home with the cache and container pools.
    private func makeFixture(label: String) throws -> (apps: URL, home: URL) {
        let base = FileManager.default.temporaryDirectory
        func canonicalDirectory(_ suffix: String) throws -> URL {
            let raw = base.appendingPathComponent("mackit-leftover-\(label)-\(suffix)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
            return URL(fileURLWithPath: FileSystem.canonical(raw.path))
        }
        let apps = try canonicalDirectory("apps")
        let home = try canonicalDirectory("home")

        // The installed app: bundle id com.example.foo, name Foo.
        let contents = apps.appendingPathComponent("Foo.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.foo",
            "CFBundleName": "Foo",
            "CFBundleShortVersionString": "3.1"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        // Pool 1: ~/Library/Caches children.
        func makeCache(_ relative: String) throws {
            let url = home.appendingPathComponent("Library/Caches/\(relative)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("cache-bytes".utf8).write(to: url.appendingPathComponent("payload.bin"))
        }
        try makeCache("com.example.foo")   // claimed: exact bundle id
        try makeCache("Foo")               // claimed: exact app name
        try makeCache("com.gone.app")      // leftover: no app claims it
        try makeCache("Google/Chrome")     // not reported: no dot in the pool entry
        try makeCache("1Password")         // protected name (excluded by name)
        try makeCache("IINA")              // protected name (excluded by name)
        try makeCache("cn.mingcui.mackit") // Mackit's own cache

        // Pool 2: caches inside sandbox containers.
        func makeContainerCache(_ container: String) throws {
            let url = home.appendingPathComponent("Library/Containers/\(container)/Data/Library/Caches/\(container)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("cache-bytes".utf8).write(to: url.appendingPathComponent("payload.bin"))
        }
        try makeContainerCache("com.gone.app")   // leftover: the container is an orphan
        try makeContainerCache("com.example.foo") // not reported: the app is installed
        // UUID-named group containers are shared by installed apps, so they
        // are never orphan candidates even though no app claims the name.
        let group = home.appendingPathComponent(
            "Library/Containers/1AC82E42-04D3-4D90-9642-2E29F25869BE/Data/Library/Caches/com.gone.three")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)

        return (apps, home)
    }

    private func cleanup(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private func paths(of items: [JunkItem]) -> [String] {
        items.map(\.path).sorted()
    }

    /// The core pool semantics: claimed, protected, self-owned, dotless and
    /// live-container entries stay out; only unclaimed reverse-DNS caches
    /// surface — one per pool.
    @Test func onlyUnclaimedReverseDNSCachesSurface() throws {
        let fixture = try makeFixture(label: "pool")
        defer { cleanup(fixture.apps, fixture.home) }

        let found = LeftoverCacheScanner.scanLeftoverCaches(
            roots: [fixture.apps.path],
            home: fixture.home.path,
            rules: [] // app claims only; rule claims are covered separately
        )

        let expected = [
            fixture.home.appendingPathComponent("Library/Caches/com.gone.app").path,
            fixture.home
                .appendingPathComponent("Library/Containers/com.gone.app/Data/Library/Caches/com.gone.app").path,
        ]
        #expect(paths(of: found) == expected.sorted(), "got \(paths(of: found))")

        for item in found {
            #expect(item.ruleID == LeftoverCacheScanner.ruleID)
            #expect(item.category == .appJunk)
            #expect(item.risk == .review, "an unclaimed cache cannot be re-attributed, so it is never preselected")
            #expect(item.appName == nil, "a leftover has no owning app")
            #expect(item.holdsLiveAppData == false, "caches are regenerable")
            #expect(item.detail == L10n.tr("apps.leftover.detail"))
        }
    }

    /// A rule that targets, digs into, or sits above a pool entry has
    /// already claimed those bytes: the pool entry must not surface.
    ///
    /// Each relation is isolated in its own scan run — one rule per run
    /// — because a single rule set cannot separate them: the ancestor
    /// relation needs a rule above every other pool entry, which would
    /// claim the positive control too. (An earlier version of this test
    /// asserted on the dotless `Google` bucket, which never surfaces for
    /// that reason alone, and on an entry a rule could not have
    /// excluded — both assertions passed with the rule claims
    /// disabled.)
    @Test func rulePrefixesClaimTheirPoolEntries() throws {
        let fixture = try makeFixture(label: "rules")
        defer { cleanup(fixture.apps, fixture.home) }

        let caches = fixture.home.appendingPathComponent("Library/Caches").path
        // The pool-2 entry no rule below touches: the positive control.
        let containerEntry = fixture.home
            .appendingPathComponent("Library/Containers/com.gone.app/Data/Library/Caches/com.gone.app").path
        for name in ["com.gone.target", "com.gone.digger/inner"] {
            try FileManager.default.createDirectory(atPath: "\(caches)/\(name)", withIntermediateDirectories: true)
        }

        func scan(rules: [ScanRule]) -> [String] {
            paths(of: LeftoverCacheScanner.scanLeftoverCaches(
                roots: [fixture.apps.path],
                home: fixture.home.path,
                rules: rules
            ))
        }

        // The rule targets the entry outright: path == prefix.
        #expect(!scan(rules: [
            ScanRule(id: "test.direct", category: .appJunk,
                     target: .children("\(caches)/com.gone.target"), risk: .safe)
        ]).contains(caches + "/com.gone.target"), "a rule targeting the entry claims it")

        // The rule digs into the entry: prefix.hasPrefix(path + "/").
        #expect(!scan(rules: [
            ScanRule(id: "test.digger", category: .appJunk,
                     target: .children("\(caches)/com.gone.digger/inner"), risk: .safe)
        ]).contains(caches + "/com.gone.digger"), "a rule digging into the entry claims it")

        // The rule sits above the entry: path.hasPrefix(prefix + "/").
        // The only ancestor a pool-1 entry has is the cache root, so
        // this rule claims every pool-1 entry — the pool-2 entry below
        // is what keeps the sweep itself honest.
        #expect(!scan(rules: [
            ScanRule(id: "test.ancestor", category: .system, target: .children(caches), risk: .safe)
        ]).contains(caches + "/com.gone.app"), "a rule above the entry claims it")

        // With all three relations armed, the sweep still reports the
        // one entry no rule touches.
        #expect(scan(rules: [
            ScanRule(id: "test.direct", category: .appJunk,
                     target: .children("\(caches)/com.gone.target"), risk: .safe),
            ScanRule(id: "test.digger", category: .appJunk,
                     target: .children("\(caches)/com.gone.digger/inner"), risk: .safe),
            ScanRule(id: "test.ancestor", category: .system, target: .children(caches), risk: .safe),
        ]).contains(containerEntry), "an entry no rule touches still surfaces")
    }

    /// A glob that starts with a wildcard has no literal prefix and claims
    /// nothing by prefix — the pool entry stays reportable.
    @Test func wildcardFirstPatternClaimsNothingByPrefix() throws {
        let fixture = try makeFixture(label: "wildcard")
        defer { cleanup(fixture.apps, fixture.home) }

        let rules = [
            ScanRule(id: "test.star", category: .system, target: .glob("*/Google"), risk: .safe)
        ]
        let found = LeftoverCacheScanner.scanLeftoverCaches(
            roots: [fixture.apps.path],
            home: fixture.home.path,
            rules: rules
        )
        // `*/Google` has an empty literal prefix, so nothing is claimed by
        // it; the entry is still dotless and stays out for that reason.
        #expect(!paths(of: found).contains(fixture.home.appendingPathComponent("Library/Caches/Google").path))
    }

    /// The bundle id's last segment claims a cache spelled after it
    /// (`com.bohemiancoding.sketch3` → `sketch3`): under-claiming would
    /// offer a live app's cache for deletion.
    @Test func bundleIDLastSegmentClaimsTheCache() throws {
        let fixture = try makeFixture(label: "segment")
        defer { cleanup(fixture.apps, fixture.home) }

        // A second installed app whose cache dir is spelled after the last
        // bundle-id segment rather than the full id.
        let contents = fixture.apps.appendingPathComponent("Sketch.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.bohemiancoding.sketch3", "CFBundleName": "Sketch"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let cache = fixture.home.appendingPathComponent("Library/Caches/sketch3")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let found = LeftoverCacheScanner.scanLeftoverCaches(
            roots: [fixture.apps.path],
            home: fixture.home.path,
            rules: []
        )
        #expect(!paths(of: found).contains(cache.path), "the last bundle-id segment claims the cache")
    }

    /// A live app's cache keeps its bundle id as a dot-bounded run in the
    /// entry name — the helper, updater and team-prefixed container
    /// spellings — and every one of them is the installed app's, not a
    /// leftover of a removed one. An app that is *not* installed keeps
    /// the same spellings unclaimed, which is what keeps the widening
    /// from swallowing the feature.
    @Test func suffixedBundleIDSpellingsAreClaimed() throws {
        let fixture = try makeFixture(label: "suffixed")
        defer { cleanup(fixture.apps, fixture.home) }

        func makeCache(_ name: String) throws {
            let url = fixture.home.appendingPathComponent("Library/Caches/\(name)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // com.example.foo is installed (see makeFixture).
        try makeCache("com.example.foo.helper")             // bundle id as a prefix
        try makeCache("com.example.foo.ShipIt")             // bundle id as a prefix, mixed case
        try makeCache("88L2Q4487U.com.example.foo.IPCHelper") // team-prefixed container spelling
        // com.gone.app is not installed: the same shapes stay leftovers.
        try makeCache("com.gone.app.helper")

        let found = LeftoverCacheScanner.scanLeftoverCaches(
            roots: [fixture.apps.path],
            home: fixture.home.path,
            rules: []
        )
        let caches = fixture.home.appendingPathComponent("Library/Caches").path
        #expect(!paths(of: found).contains("\(caches)/com.example.foo.helper"),
                "an installed app's helper cache is claimed")
        #expect(!paths(of: found).contains("\(caches)/com.example.foo.ShipIt"),
                "an installed app's updater cache is claimed")
        #expect(!paths(of: found).contains("\(caches)/88L2Q4487U.com.example.foo.IPCHelper"),
                "a team-prefixed container of an installed app is claimed")
        #expect(paths(of: found).contains("\(caches)/com.gone.app.helper"),
                "the claim follows the app, not the spelling: an uninstalled app's helper cache still surfaces")
    }

    /// The view-model phase: sizes are filled in by the shared measurement
    /// pass and the entries merge into the list.
    @MainActor
    @Test func scanLeftoversMergesMeasuredEntriesIntoTheList() async throws {
        let fixture = try makeFixture(label: "vm")
        defer { cleanup(fixture.apps, fixture.home) }

        let vm = AppViewModel(statsPolling: false)
        await vm.scanLeftovers(roots: [fixture.apps.path], home: fixture.home.path)

        #expect(vm.progressLabel == L10n.tr("scan.leftovers"))
        #expect(vm.items.count == 2, "one leftover per pool, got \(paths(of: vm.items))")
        #expect(vm.items.allSatisfy { $0.size > 0 }, "sizes are filled in after the scan")
        #expect(vm.items.allSatisfy { $0.ruleID == LeftoverCacheScanner.ruleID })
        #expect(vm.categoryCounts[.appJunk] == 2)
    }
}
