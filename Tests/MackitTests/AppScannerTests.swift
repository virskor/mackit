import Foundation
import Testing

@testable import Mackit

/// Tests for app discovery and residue detection.
///
/// All of them construct fake .app bundles and fake home directories via
/// temporary directories, never touching the real /Applications or ~/Library.
struct AppScannerTests {
    /// Creates a fake .app: writes the given keys and values into
    /// Contents/Info.plist.
    private func makeApp(
        at directory: URL,
        name: String,
        bundleID: String? = nil,
        version: String? = nil,
        displayName: String? = nil,
        writeInfoPlist: Bool = true
    ) {
        let contents = directory.appendingPathComponent(name).appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        guard writeInfoPlist else { return }
        var plist: [String: Any] = [:]
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        if let displayName { plist["CFBundleDisplayName"] = displayName }
        plist["CFBundleName"] = (name as NSString).deletingPathExtension
        if let version { plist["CFBundleShortVersionString"] = version }
        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try? data?.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func tempDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-appscan-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // FileManager's contentsOfDirectory returns paths with symlinks
        // resolved (/var → /private/var), while paths built by string
        // concatenation do not. Normalizing the temporary directory puts both
        // kinds of paths under the same representation for comparison.
        return URL(fileURLWithPath: canonical(url.path))
    }

    /// Resolves symlinks in a path to the real path (realpath), matching what
    /// contentsOfDirectory returns.
    private func canonical(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer) != nil ? String(cString: buffer) : path
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeDirectory(_ path: String, under home: URL) {
        let url = home.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeFile(_ path: String, under home: URL) {
        let url = home.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: url)
    }

    // MARK: - Discovery

    @Test func discoveryFindsAppBundlesAndSkipsInvalid() {
        let appsDir = tempDirectory("apps")
        defer { cleanup(appsDir) }

        makeApp(at: appsDir, name: "Foo.app", bundleID: "com.example.foo", version: "1.2.3")
        makeApp(at: appsDir, name: "Bar.app", bundleID: "com.example.bar")
        makeApp(at: appsDir, name: "NoPlist.app", writeInfoPlist: false)
        makeApp(at: appsDir, name: "NoBundleID.app", version: "1.0")
        makeApp(at: appsDir, name: "NotAnApp", bundleID: "com.example.notanapp")
        // A fake .app with the same name but only a plain file
        try? Data("x".utf8).write(to: appsDir.appendingPathComponent("Fake.app"))

        let apps = AppScanner.discoverApps(roots: [appsDir.path])

        #expect(apps.count == 2, "只应发现 Foo 与 Bar，实际 \(apps.count)")
        // Sorted by name to keep the list order stable
        #expect(apps.map(\.name) == ["Bar", "Foo"])
        let foo = apps.first { $0.name == "Foo" }!
        #expect(foo.bundleID == "com.example.foo")
        #expect(foo.version == "1.2.3")
        #expect(foo.path == appsDir.appendingPathComponent("Foo.app").path)
        let bar = apps.first { $0.name == "Bar" }!
        #expect(bar.version == "", "缺少 CFBundleShortVersionString 时版本为空")
    }

    @Test func discoveryDeduplicatesAcrossRoots() {
        let root = tempDirectory("roots")
        defer { cleanup(root) }

        makeApp(at: root, name: "Foo.app", bundleID: "com.example.foo", version: "1.0")

        // The same root passed twice: enumeration yields two identical paths,
        // deduplicated by path down to one
        let apps = AppScanner.discoverApps(roots: [root.path, root.path])
        #expect(apps.count == 1)
    }

    @Test func discoveryReturnsEmptyForMissingRoot() {
        #expect(AppScanner.discoverApps(roots: ["/definitely/not/a/real/path"]).isEmpty)
    }

    /// System apps with com.apple.* cannot be uninstalled, and their residue
    /// data is protected by TCC (probing triggers an authorization prompt), so
    /// they are skipped during discovery.
    @Test func discoverySkipsSystemApps() {
        let appsDir = tempDirectory("system-apps")
        defer { cleanup(appsDir) }

        makeApp(at: appsDir, name: "Safari.app", bundleID: "com.apple.Safari", version: "18.0")
        makeApp(at: appsDir, name: "Music.app", bundleID: "com.apple.Music", version: "1.0")
        makeApp(at: appsDir, name: "Chrome.app", bundleID: "com.google.Chrome", version: "1.0")

        let apps = AppScanner.discoverApps(roots: [appsDir.path])
        #expect(apps.count == 1, "只应发现第三方应用，实际：\(apps.map(\.bundleID))")
        #expect(apps.first?.bundleID == "com.google.Chrome")
    }

    @Test func displayNameTakesPrecedenceOverBundleName() {
        let appsDir = tempDirectory("display-name")
        defer { cleanup(appsDir) }

        makeApp(at: appsDir, name: "Chrome.app", bundleID: "com.google.chrome", version: "1.0", displayName: "Google Chrome")

        let apps = AppScanner.discoverApps(roots: [appsDir.path])
        #expect(apps.count == 1)
        #expect(apps[0].name == "Google Chrome", "展示名应优先，与 Finder 里的名字一致")
    }

    // MARK: - Residue detection

    @Test func residueProbeFindsOnlyExistingPaths() {
        let home = tempDirectory("home")
        defer { cleanup(home) }

        makeDirectory("Library/Application Support/com.example.foo", under: home)
        makeDirectory("Library/Application Support/Foo", under: home)
        makeDirectory("Library/Caches/com.example.foo", under: home)
        makeDirectory("Library/Containers/com.example.foo", under: home)
        makeFile("Library/Preferences/com.example.foo.plist", under: home)
        makeFile("Library/Preferences/ByHost/com.example.foo.A1B2C3.plist", under: home)
        makeFile("Library/Preferences/ByHost/com.other.app.plist", under: home)
        makeDirectory("Library/Saved Application State/com.example.foo.savedState", under: home)
        makeDirectory("Library/Logs/Foo", under: home)
        makeFile("Library/Application Support/CrashReporter/Foo-2024-01-01.ips", under: home)
        makeFile("Library/Logs/DiagnosticReports/Foo-2024-01-01.ips", under: home)

        let app = InstalledApp(name: "Foo", bundleID: "com.example.foo", version: "1.0", path: "/Applications/Foo.app")
        let found = AppScanner.residuePaths(for: app, home: home.path)

        let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.path, $0.kind) })
        #expect(byPath.count == found.count, "同一路径不应重复出现")

        let expected: [(String, ResidueKind)] = [
            ("Library/Application Support/com.example.foo", .applicationSupport),
            ("Library/Application Support/Foo", .applicationSupport),
            ("Library/Caches/com.example.foo", .caches),
            ("Library/Containers/com.example.foo", .containers),
            ("Library/Preferences/com.example.foo.plist", .preferences),
            ("Library/Preferences/ByHost/com.example.foo.A1B2C3.plist", .preferences),
            ("Library/Saved Application State/com.example.foo.savedState", .savedState),
            ("Library/Logs/Foo", .logs),
            ("Library/Application Support/CrashReporter/Foo-2024-01-01.ips", .crashReports),
            ("Library/Logs/DiagnosticReports/Foo-2024-01-01.ips", .diagnosticReports)
        ]
        #expect(found.count == expected.count, "应恰好发现 \(expected.count) 条残留，实际 \(found.count)：\(found.map(\.path))")
        for (relative, kind) in expected {
            let path = home.appendingPathComponent(relative).path
            #expect(byPath[path] == kind, "\(relative) 的种类应为 \(kind.rawValue)")
        }
        // Someone else's ByHost preference must not be matched
        #expect(byPath[home.appendingPathComponent("Library/Preferences/ByHost/com.other.app.plist").path] == nil)
    }

    @Test func residueProbeReturnsEmptyForCleanHome() {
        let home = tempDirectory("empty-home")
        defer { cleanup(home) }
        let app = InstalledApp(name: "Foo", bundleID: "com.example.foo", version: "1.0", path: "/Applications/Foo.app")
        #expect(AppScanner.residuePaths(for: app, home: home.path).isEmpty)
    }

    @Test func residueKindsMapToExpectedRisks() {
        let safe: [ResidueKind] = [.caches, .httpStorages, .webKit, .cookies, .logs, .crashReports, .diagnosticReports]
        let review: [ResidueKind] = [.applicationSupport, .containers, .preferences, .savedState, .applicationScripts, .launchAgents]
        for kind in safe {
            #expect(kind.risk == .safe, "\(kind.rawValue) 应为安全级")
        }
        for kind in review {
            #expect(kind.risk == .review, "\(kind.rawValue) 应为留意级")
        }
        // CaseIterable matches the localization key coverage; a missing one
        // exposes the key in the UI
        #expect(ResidueKind.allCases.count == safe.count + review.count)
        for kind in ResidueKind.allCases {
            #expect(!kind.labelKey.isEmpty)
        }
    }

    // MARK: - Application Support index

    @Test func supportIndexMatchesVendorNestedDirectories() {
        let home = tempDirectory("index-home")
        defer { cleanup(home) }

        makeDirectory("Library/Application Support/Google/Chrome", under: home)
        makeDirectory("Library/Application Support/Google/Chrome/Default", under: home)
        makeDirectory("Library/Application Support/Code", under: home)

        let index = AppScanner.supportIndex(home: home.path)
        let chromePath = home.appendingPathComponent("Library/Application Support/Google/Chrome").path
        let codePath = home.appendingPathComponent("Library/Application Support/Code").path

        // Vendor subdirectories match on every word of the app name
        // consecutively
        #expect(index.paths(matching: "Google Chrome") == [chromePath])
        // Matching is case-insensitive
        #expect(index.paths(matching: "google chrome").count == 1)
        // Top-level directories match by word
        #expect(index.paths(matching: "Code") == [codePath])
        #expect(index.paths(matching: "Google").count == 1)
        // A single word does not guess vendor subdirectories: an app called
        // "Chrome" must not claim Google's data as its own residue (this once
        // matched Google/Chrome to any app whose name contains Chrome)
        #expect(index.paths(matching: "Chrome").isEmpty)
        // Directories at the third level or deeper are not indexed
        #expect(index.paths(matching: "Default").isEmpty)
    }

    @Test func supportIndexReturnsEmptyForMissingHome() {
        let index = AppScanner.supportIndex(home: "/definitely/not/a/real/path")
        #expect(index.paths(matching: "Anything").isEmpty)
    }

    // MARK: - Item generation

    @Test func appDetailComposesVersionAndResidueCount() {
        #expect(AppScanner.appDetail(version: "2.0", residueCount: 0).contains("2.0"))
        #expect(AppScanner.appDetail(version: "", residueCount: 0).isEmpty)
        #expect(!AppScanner.appDetail(version: "2.0", residueCount: 0).contains("·"))

        let both = AppScanner.appDetail(version: "2.0", residueCount: 3)
        #expect(both.contains("2.0"))
        #expect(both.contains("3"))
    }

    @Test func itemsForAppProducesBundleAndResidueItems() {
        let home = tempDirectory("items-home")
        defer { cleanup(home) }
        makeDirectory("Library/Caches/com.example.foo", under: home)
        makeFile("Library/Preferences/com.example.foo.plist", under: home)

        let app = InstalledApp(name: "Foo", bundleID: "com.example.foo", version: "2.0", path: "/Applications/Foo.app")
        let items = AppScanner.items(for: app, home: home.path)

        #expect(items.count == 3, "1 个本体 + 2 条残留")
        let bundle = items[0]
        #expect(bundle.appKind == .bundle)
        #expect(bundle.category == .apps)
        #expect(bundle.risk == .caution)
        #expect(bundle.isDirectory)
        #expect(bundle.path == app.path)
        #expect(bundle.title == "Foo")
        #expect(bundle.bundleID == "com.example.foo")
        // The bundle ID is searchable but does not go into the subtitle
        #expect(bundle.searchBlob.contains("com.example.foo"))
        #expect(!bundle.detail.contains("com.example.foo"))
        #expect(bundle.detail.contains("2.0"))
        #expect(bundle.id == "app.bundle::/Applications/Foo.app")

        let residues = items.dropFirst()
        #expect(residues.allSatisfy { $0.appKind?.isResidue == true })
        #expect(residues.allSatisfy { $0.category == .apps })
        #expect(residues.allSatisfy { $0.bundleID == app.bundleID })
        #expect(residues.allSatisfy { $0.detail.contains("Foo") })
        #expect(Set(items.map(\.id)).count == items.count, "条目 id 必须唯一")
        // Residue rows do not show a real icon; the category symbol is the
        // fallback
        #expect(residues.allSatisfy { $0.appKind != .bundle })
    }

    @Test func scanAppsComposesDiscoveryAndResidues() {
        let appsDir = tempDirectory("scan-apps")
        let home = tempDirectory("scan-home")
        defer { cleanup(appsDir); cleanup(home) }

        makeApp(at: appsDir, name: "Foo.app", bundleID: "com.example.foo", version: "1.0")
        makeApp(at: appsDir, name: "Bar.app", bundleID: "com.example.bar", version: "2.0")
        makeDirectory("Library/Caches/com.example.foo", under: home)

        let items = AppScanner.scanApps(roots: [appsDir.path], home: home.path)

        let bundles = items.filter { $0.appKind == .bundle }
        #expect(bundles.count == 2)
        // Foo has one cache residue, Bar has none
        #expect(items.count == 3)
        #expect(Set(items.map(\.id)).count == items.count)
    }

    // MARK: - Clean engine running-app checks

    @Test func cleanSkipsRunningAppButKeepsResidues() async throws {
        let dir = tempDirectory("uninstall")
        defer { cleanup(dir) }

        let appPath = dir.appendingPathComponent("Foo.app").path
        let residuePath = dir.appendingPathComponent("com.example.foo").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: appPath))
        try Data("x".utf8).write(to: URL(fileURLWithPath: residuePath))

        let app = JunkItem(
            ruleID: "app.bundle", title: "Foo", detail: "", path: appPath,
            category: .apps, risk: .caution, size: 10,
            bundleID: "com.example.foo", appKind: .bundle
        )
        let residue = JunkItem(
            ruleID: "app.residue", title: "com.example.foo", detail: "", path: residuePath,
            category: .apps, risk: .safe, size: 5,
            bundleID: "com.example.foo", appKind: .residue(.caches)
        )

        var outcomes: [CleanOutcome] = []
        let stream = CleanEngine.clean(
            items: [app, residue],
            moveToTrash: false,
            isAppRunning: { $0 == "com.example.foo" }
        )
        for await event in stream {
            if case .outcome(let outcome) = event { outcomes.append(outcome) }
        }

        #expect(outcomes.count == 2)
        let appOutcome = outcomes.first { $0.itemID == app.id }
        let residueOutcome = outcomes.first { $0.itemID == residue.id }
        #expect(appOutcome?.succeeded == false, "运行中的应用必须被拒绝")
        #expect(appOutcome?.message.contains("Foo") == true, "失败信息应点出应用名")
        // Residue files are refused as well: caches, application support, and
        // similar data are being read and written by a running process in real
        // time; protecting only the .app bundle is like pulling live data out
        // from under the process.
        #expect(residueOutcome?.succeeded == false, "运行中应用的残留文件也必须被拒绝")
        #expect(FileManager.default.fileExists(atPath: appPath), "应用本体不应被删除")
        #expect(FileManager.default.fileExists(atPath: residuePath), "残留文件不应被删除")
    }

    @Test func cleanAllowsNonRunningApp() async throws {
        let dir = tempDirectory("uninstall-ok")
        defer { cleanup(dir) }

        let appPath = dir.appendingPathComponent("Bar.app").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: appPath))

        let app = JunkItem(
            ruleID: "app.bundle", title: "Bar", detail: "", path: appPath,
            category: .apps, risk: .caution, size: 10,
            bundleID: "com.example.bar", appKind: .bundle
        )

        var outcomes: [CleanOutcome] = []
        let stream = CleanEngine.clean(items: [app], moveToTrash: false, isAppRunning: { _ in false })
        for await event in stream {
            if case .outcome(let outcome) = event { outcomes.append(outcome) }
        }

        #expect(outcomes.count == 1)
        #expect(outcomes[0].succeeded)
        #expect(!FileManager.default.fileExists(atPath: appPath))
    }
}
