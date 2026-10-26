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
    /// contentsOfDirectory returns. The app's own canonicalizer, so the two
    /// spellings can never drift apart.
    private func canonical(_ path: String) -> String {
        FileSystem.canonical(path)
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

        #expect(apps.count == 2, "should only find Foo and Bar, got \(apps.count)")
        // Sorted by name to keep the list order stable
        #expect(apps.map(\.name) == ["Bar", "Foo"])
        let foo = apps.first { $0.name == "Foo" }!
        #expect(foo.bundleID == "com.example.foo")
        #expect(foo.version == "1.2.3")
        #expect(foo.path == appsDir.appendingPathComponent("Foo.app").path)
        let bar = apps.first { $0.name == "Bar" }!
        #expect(bar.version == "", "version is empty when CFBundleShortVersionString is missing")
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

    /// A discovery root that is itself a symlink must still be listed. The bulk
    /// enumeration opens with O_DIRECTORY, which refuses to follow a link
    /// (ENOTDIR, verified), so a user who moved `~/Applications` to another
    /// volume and linked it back used to get "no apps installed".
    /// A discovery root that is itself a symlink must still be listed. The bulk
    /// enumeration opens directories with `open(O_DIRECTORY)`, which follows a
    /// link — unlike Foundation's URL-based `contentsOfDirectory(at:)`, which
    /// refuses one — so the apps are found and reported under the spelling the
    /// user configured. Pinned because swapping this listing for the URL-based
    /// API would silently break it.
    @Test func discoveryFollowsASymlinkedRoot() throws {
        let base = tempDirectory("symlink-apps")
        defer { cleanup(base) }
        makeApp(at: base, name: "Real.app", bundleID: "com.example.real", version: "1.0")
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("Link.app"),
            withDestinationURL: base.appendingPathComponent("Real.app")
        )
        // The root itself is the link: a directory that only exists under that
        // spelling.
        let linked = base.appendingPathComponent("AppsLink")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: base)

        let apps = AppScanner.discoverApps(roots: [linked.path])

        #expect(apps.count == 1, "a symlinked root listed \(apps.count) apps: \(apps.map(\.bundleID))")
        #expect(apps.first?.bundleID == "com.example.real")
        // Reported as the user spelled the root: the link is what they see.
        #expect(apps.first?.path == linked.appendingPathComponent("Real.app").path)
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
        #expect(apps.count == 1, "should only find third-party apps, got: \(apps.map(\.bundleID))")
        #expect(apps.first?.bundleID == "com.google.Chrome")
    }

    @Test func displayNameTakesPrecedenceOverBundleName() {
        let appsDir = tempDirectory("display-name")
        defer { cleanup(appsDir) }

        makeApp(at: appsDir, name: "Chrome.app", bundleID: "com.google.chrome", version: "1.0", displayName: "Google Chrome")

        let apps = AppScanner.discoverApps(roots: [appsDir.path])
        #expect(apps.count == 1)
        #expect(apps[0].name == "Google Chrome", "display name takes precedence, matching the name in Finder")
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
        #expect(byPath.count == found.count, "the same path should not appear twice")

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
        #expect(found.count == expected.count, "should find exactly \(expected.count) leftovers, got \(found.count): \(found.map(\.path))")
        for (relative, kind) in expected {
            let path = home.appendingPathComponent(relative).path
            #expect(byPath[path] == kind, "\(relative) kind should be \(kind.rawValue)")
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

    // MARK: - Probe keys are untrusted input

    /// The bundle id and the app name come from the bundle's own Info.plist, so
    /// they are attacker-controlled data that gets spliced into probe paths.
    /// A component that is not a plain file name is refused outright.
    @Test func onlyPlainFileNamesAreSafeProbeComponents() {
        #expect(AppScanner.isSafeComponent("com.example.foo"))
        #expect(AppScanner.isSafeComponent("Foo"))
        #expect(AppScanner.isSafeComponent("Google Chrome"))
        #expect(AppScanner.isSafeComponent("dot.ted"))

        #expect(!AppScanner.isSafeComponent(""), "an empty component addresses the parent directory")
        #expect(!AppScanner.isSafeComponent("."), "the current directory is not a residue location")
        #expect(!AppScanner.isSafeComponent(".."), "the parent directory is how a probe escapes its own folder")
        #expect(!AppScanner.isSafeComponent("a/b"), "a separator addresses a different directory")
        #expect(!AppScanner.isSafeComponent("/etc"), "an absolute component ignores the home prefix")
        #expect(!AppScanner.isSafeComponent("a\0b"), "a NUL truncates the path at the C boundary")
        #expect(!AppScanner.isSafeComponent("bell\u{7}"), "a control character has no place in a file name")
    }

    /// A bundle directory called `..app` resolves to the app name "..", which
    /// spliced into `Library/Application Support/..` resolves to `~/Library`
    /// itself. The residue list would then offer the whole Library folder as
    /// one app's leftovers — the most destructive thing this app can do.
    @Test func anAppNamedLikeAParentDirectoryClaimsNothing() {
        let home = tempDirectory("traversal-home")
        defer { cleanup(home) }
        // What such a bundle's probe would resolve to if it were accepted: the
        // probed directory itself has to exist for the ".." to resolve.
        makeDirectory("Library/Application Support", under: home)
        makeFile("Library/sentinel.txt", under: home)

        let app = InstalledApp(name: "..", bundleID: "com.example.dots", version: "1.0", path: "/Applications/..app")
        let found = AppScanner.residuePaths(for: app, home: home.path)

        #expect(found.isEmpty, "an app named \"..\" claimed \(found.map(\.path))")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/sentinel.txt").path))
    }

    /// A crafted `CFBundleIdentifier` is the other way in: `../../Documents`
    /// resolves out of the probed directory and into the user's own files.
    @Test func aCraftedBundleIDCannotEscapeTheHomeTree() {
        let home = tempDirectory("escape-home")
        defer { cleanup(home) }
        makeDirectory("Library/Application Support", under: home)
        makeDirectory("Documents", under: home)
        makeFile("Documents/private.txt", under: home)

        let app = InstalledApp(name: "Normal", bundleID: "../../Documents", version: "1.0", path: "/Applications/Evil.app")
        let found = AppScanner.residuePaths(for: app, home: home.path)

        #expect(found.isEmpty, "a crafted bundle id claimed \(found.map(\.path))")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Documents/private.txt").path))
    }

    /// The backstop behind the component check: a residue directory that is a
    /// symlink pointing outside the home tree resolves there, and the resolved
    /// path is what would be deleted. Residue lives under the home directory,
    /// so it is dropped rather than offered.
    @Test func residueThatResolvesOutsideTheHomeTreeIsDropped() throws {
        let home = tempDirectory("symlink-home")
        defer { cleanup(home) }
        let outside = tempDirectory("outside-home")
        defer { cleanup(outside) }
        makeDirectory("Library/Application Support/com.example.foo", under: outside)
        makeFile("outside.txt", under: outside)
        // The link has to sit inside a real Application Support directory for
        // the probe to reach it at all.
        makeDirectory("Library/Application Support", under: home)

        // The residue spelling a well-behaved app would produce, pointing at a
        // directory that lives somewhere else entirely.
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Library/Application Support/com.example.foo"),
            withDestinationURL: outside.appendingPathComponent("Library/Application Support/com.example.foo")
        )

        let app = InstalledApp(name: "Foo", bundleID: "com.example.foo", version: "1.0", path: "/Applications/Foo.app")
        let found = AppScanner.residuePaths(for: app, home: home.path)

        #expect(found.isEmpty, "residue resolved outside the home tree: \(found.map(\.path))")
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("outside.txt").path))
    }

    /// The checks must not cost the ordinary case anything: a well-behaved app
    /// still has every one of its leftovers found.
    @Test func aWellBehavedAppStillFindsItsResidue() {
        let home = tempDirectory("normal-home")
        defer { cleanup(home) }
        makeDirectory("Library/Application Support/com.example.foo", under: home)
        makeDirectory("Library/Caches/com.example.foo", under: home)
        makeDirectory("Library/Logs/Foo", under: home)

        let app = InstalledApp(name: "Foo", bundleID: "com.example.foo", version: "1.0", path: "/Applications/Foo.app")
        let found = AppScanner.residuePaths(for: app, home: home.path)

        #expect(found.count == 3, "the containment checks cost the ordinary case: \(found.map(\.path))")
        #expect(found.allSatisfy { $0.path.hasPrefix(home.path + "/") })
    }

    @Test func residueKindsMapToExpectedRisks() {
        let safe: [ResidueKind] = [.caches, .httpStorages, .webKit, .cookies, .logs, .crashReports, .diagnosticReports]
        let review: [ResidueKind] = [.applicationSupport, .containers, .preferences, .savedState, .applicationScripts, .launchAgents]
        for kind in safe {
            #expect(kind.risk == .safe, "\(kind.rawValue) should be safe level")
        }
        for kind in review {
            #expect(kind.risk == .review, "\(kind.rawValue) should be review level")
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

    /// An Application Support relocated through a link must still be indexed.
    /// The listing opens with `open(O_DIRECTORY)`, which follows the link, so
    /// vendor subdirectory matching (Google/Chrome and friends) keeps working;
    /// the paths come back in the spelling the home was given. Pinned because
    /// swapping this listing for Foundation's URL-based
    /// `contentsOfDirectory(at:)` would silently index nothing.
    @Test func supportIndexFollowsASymlinkedApplicationSupport() throws {
        let home = tempDirectory("symlink-support-home")
        defer { cleanup(home) }
        let real = tempDirectory("symlink-support-real")
        defer { cleanup(real) }
        makeDirectory("Library/Application Support/Google/Chrome", under: real)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Library/Application Support"),
            withDestinationURL: real.appendingPathComponent("Library/Application Support")
        )

        let index = AppScanner.supportIndex(home: home.path)

        #expect(
            index.paths(matching: "Google Chrome") == [home.appendingPathComponent("Library/Application Support/Google/Chrome").path],
            "a linked Application Support indexed nothing"
        )
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

        #expect(items.count == 3, "1 bundle + 2 leftovers")
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
        #expect(residues.allSatisfy { $0.bundleID == app.bundleID })
        #expect(residues.allSatisfy { $0.detail.contains("Foo") })
        #expect(Set(items.map(\.id)).count == items.count, "item ids must be unique")
        // Residue rows do not show a real icon; the category symbol is the
        // fallback
        #expect(residues.allSatisfy { $0.appKind != .bundle })

        // The split by what a residue holds: the cache is regenerable junk and
        // belongs to the general module's app-junk row, the preferences file is
        // app data and stays with the bundle in the uninstall flow. Both still
        // carry the bundle ID, so uninstalling selects the cache too.
        let cache = items.first { $0.appKind == .residue(.caches) }!
        #expect(cache.category == .appJunk)
        #expect(cache.ruleID == AppScanner.junkRuleID)
        #expect(cache.risk == .safe)
        #expect(cache.holdsLiveAppData == false)
        #expect(cache.appName == "Foo")

        let prefs = items.first { $0.appKind == .residue(.preferences) }!
        #expect(prefs.category == .apps)
        #expect(prefs.ruleID == AppScanner.residueRuleID)
        #expect(prefs.risk == .review)
        #expect(prefs.holdsLiveAppData == true)
        #expect(prefs.appName == "Foo")

        // The bundle itself is live data: uninstalling a running app is refused
        #expect(bundle.holdsLiveAppData)
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

    /// The composition the cleanup scan itself runs: regenerable junk only.
    /// The general module's app-junk row must never see an app bundle or a
    /// data residue — those belong to the uninstall tool, and a scan that
    /// listed them would make app data reachable from "clean everything".
    @Test func scanAppJunkYieldsOnlyRegenerableJunk() {
        let appsDir = tempDirectory("scan-junk")
        let home = tempDirectory("scan-junk-home")
        defer { cleanup(appsDir); cleanup(home) }

        makeApp(at: appsDir, name: "Foo.app", bundleID: "com.example.foo", version: "1.0")
        makeDirectory("Library/Caches/com.example.foo", under: home)
        makeFile("Library/Preferences/com.example.foo.plist", under: home)
        makeDirectory("Library/Application Support/com.example.foo", under: home)

        let junk = AppScanner.scanAppJunk(roots: [appsDir.path], home: home.path)

        #expect(junk.count == 1, "only the cache is regenerable junk, got \(junk.map(\.path))")
        let cache = junk[0]
        #expect(cache.category == .appJunk)
        #expect(cache.ruleID == AppScanner.junkRuleID)
        #expect(cache.appKind == .residue(.caches))
        #expect(cache.holdsLiveAppData == false)
        // Every entry still carries the app identity the general page groups by
        #expect(cache.bundleID == "com.example.foo")
        #expect(cache.appName == "Foo")
    }

    @Test func scanAppJunkReturnsEmptyForCleanHome() {
        let appsDir = tempDirectory("scan-junk-clean")
        let home = tempDirectory("scan-junk-clean-home")
        defer { cleanup(appsDir); cleanup(home) }

        makeApp(at: appsDir, name: "Foo.app", bundleID: "com.example.foo", version: "1.0")
        makeFile("Library/Preferences/com.example.foo.plist", under: home)

        #expect(AppScanner.scanAppJunk(roots: [appsDir.path], home: home.path).isEmpty)
    }

    // MARK: - Clean engine running-app checks

    /// The running-app guard is scoped to what deleting it would actually
    /// break: the app's own bundle and residue that holds live data are
    /// refused, while regenerable junk is deleted — an app rebuilds a cache on
    /// demand, so refusing it would only make the clean report failures for
    /// files the app does not need.
    @Test func runningAppRefusesBundleAndLiveDataButDeletesJunk() async throws {
        let dir = tempDirectory("uninstall")
        defer { cleanup(dir) }

        let appPath = dir.appendingPathComponent("Foo.app").path
        let cachePath = dir.appendingPathComponent("com.example.foo").path
        let prefsPath = dir.appendingPathComponent("com.example.foo.plist").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: appPath))
        try Data("x".utf8).write(to: URL(fileURLWithPath: cachePath))
        try Data("x".utf8).write(to: URL(fileURLWithPath: prefsPath))

        let app = JunkItem(
            ruleID: "app.bundle", title: "Foo", detail: "", path: appPath,
            category: .apps, risk: .caution, size: 10,
            bundleID: "com.example.foo", appKind: .bundle, holdsLiveAppData: true
        )
        let cache = JunkItem(
            ruleID: "app.junk", title: "com.example.foo", detail: "", path: cachePath,
            category: .appJunk, risk: .safe, size: 5,
            bundleID: "com.example.foo", appKind: .residue(.caches), appName: "Foo"
        )
        let prefs = JunkItem(
            ruleID: "app.residue", title: "com.example.foo.plist", detail: "", path: prefsPath,
            category: .apps, risk: .review, size: 5,
            bundleID: "com.example.foo", appKind: .residue(.preferences), holdsLiveAppData: true
        )

        var outcomes: [CleanOutcome] = []
        let stream = CleanEngine.clean(
            items: [app, cache, prefs],
            moveToTrash: false,
            isAppRunning: { $0 == "com.example.foo" }
        )
        for await event in stream {
            if case .outcome(let outcome) = event { outcomes.append(outcome) }
        }

        #expect(outcomes.count == 3)
        let appOutcome = outcomes.first { $0.itemID == app.id }
        let cacheOutcome = outcomes.first { $0.itemID == cache.id }
        let prefsOutcome = outcomes.first { $0.itemID == prefs.id }
        #expect(appOutcome?.succeeded == false, "a running app must be refused")
        #expect(appOutcome?.message.contains("Foo") == true, "the failure message should name the app")
        // Caches, application support, and preferences are being read and
        // written by a running process in real time; deleting them pulls live
        // data out from under the process, so they are refused too.
        #expect(prefsOutcome?.succeeded == false, "a running app's preferences must be refused")
        #expect(FileManager.default.fileExists(atPath: appPath), "the app bundle should not be deleted")
        #expect(FileManager.default.fileExists(atPath: prefsPath), "the preferences should not be deleted")
        // The cache is rebuilt on demand, so it goes even while the app runs
        #expect(cacheOutcome?.succeeded == true, "a running app's cache can be cleaned")
        #expect(!FileManager.default.fileExists(atPath: cachePath))
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
