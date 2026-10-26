import Foundation

/// An installed app and its Info.plist metadata.
struct InstalledApp: Sendable, Hashable {
    /// The display name, taken from CFBundleName / CFBundleDisplayName, falling back to the directory name with the .app suffix removed.
    let name: String
    let bundleID: String
    /// CFBundleShortVersionString, falling back to CFBundleVersion when missing, and to an empty string if that is also missing.
    let version: String
    /// The absolute path of the .app bundle.
    let path: String
}

/// The discovery engine for installed apps: their bundles, their regenerable
/// junk, and the data they leave behind.
///
/// The difference from cache rules is that app entries are not static paths:
/// the .app's Info.plist must be read, then associated residue files are
/// probed across `~/Library` by bundle ID and app name. Discoveries take the
/// same path as "project directory scanning": they are handed to the caller
/// to have their sizes filled in and merged into the list.
///
/// Residue is split by what it holds (see `ResidueKind.isRegenerableJunk`):
/// regenerable junk becomes general-module app-junk entries, so a user can
/// sweep an app's caches without uninstalling it, while data (preferences,
/// Application Support, containers, cookies…) stays with the bundle, which is
/// what the uninstall tool (`AppUninstallModel`) lists and removes together.
/// The split also keeps the two surfaces' path sets disjoint — the same
/// directory never appears in both.
enum AppScanner {
    /// Default discovery locations: system-level and user-level Applications.
    static let defaultRoots = ["/Applications", "~/Applications"]

    /// Rule id: the app bundle itself. Only the uninstall tool lists it.
    static let bundleRuleID = "app.bundle"
    /// Rule id: residue files that hold app data (preferences, Application
    /// Support, containers…). They stay with the app bundle in the uninstall
    /// tool, where deleting them is the user's explicit intent.
    static let residueRuleID = "app.residue"
    /// Rule id: regenerable residue (caches, HTTP storages, WebKit data). They
    /// roll up into the general module's app-junk row, so an app's caches can
    /// be swept without uninstalling anything.
    static let junkRuleID = "app.junk"

    // MARK: - Composition entry point

    /// Discover apps and generate all entries (one bundle entry per app + several residue entries).
    static func scanApps(roots: [String] = defaultRoots, home: String = NSHomeDirectory()) -> [JunkItem] {
        let apps = discoverApps(roots: roots)
        guard !apps.isEmpty else { return [] }
        // The Application Support index is built by one shallow traversal shared by all apps
        let index = supportIndex(home: home)
        return apps.flatMap { items(for: $0, home: home, index: index) }
    }

    /// Discover apps and generate only their regenerable-junk entries — what
    /// the general cleanup module's app-junk row sweeps. The main scan no
    /// longer lists apps for uninstalling (that lives in `AppUninstallModel`),
    /// so this is the only composition the scan itself runs; it deliberately
    /// produces no bundle entries and no data residue, so no app data is ever
    /// reachable from the cleanup scan.
    static func scanAppJunk(roots: [String] = defaultRoots, home: String = NSHomeDirectory()) -> [JunkItem] {
        let apps = discoverApps(roots: roots)
        guard !apps.isEmpty else { return [] }
        // No Application Support index: the only residue kind it can add is
        // application support, which is app data the junk scan filters out
        // anyway — building the index here would charge every cleanup scan a
        // shallow ~/Library/Application Support traversal for nothing.
        return apps.flatMap { items(for: $0, home: home, index: nil) }
            .filter { $0.category == .appJunk }
    }

    /// All entries for a single app: the bundle first, with junk residue
    /// following and data residue last, in probing order.
    ///
    /// A nil `index` means no Application Support index at all — vendor
    /// subdirectories are then not matched. Callers that want them build the
    /// index once and pass it in (`scanApps`); building it here would charge
    /// every caller for a traversal only some of them use.
    static func items(for app: InstalledApp, home: String, index: SupportIndex? = nil) -> [JunkItem] {
        let residues = residuePaths(for: app, home: home, index: index)
        let junk = residues
            .filter { $0.kind.isRegenerableJunk }
            .map { residueItem(for: $0, app: app, ruleID: junkRuleID, category: .appJunk, holdsLiveAppData: false) }
        let data = residues
            .filter { !$0.kind.isRegenerableJunk }
            .map { residueItem(for: $0, app: app, ruleID: residueRuleID, category: .apps, holdsLiveAppData: true) }
        let bundle = JunkItem(
            ruleID: bundleRuleID,
            title: app.name,
            detail: appDetail(version: app.version, residueCount: junk.count + data.count),
            path: app.path,
            category: .apps,
            risk: .caution,
            isDirectory: true,
            bundleID: app.bundleID,
            appKind: .bundle,
            holdsLiveAppData: true,
            searchExtra: app.bundleID
        )
        return [bundle] + junk + data
    }

    private static func residueItem(
        for entry: ResidueEntry,
        app: InstalledApp,
        ruleID: String,
        category: JunkCategory,
        holdsLiveAppData: Bool
    ) -> JunkItem {
        JunkItem(
            ruleID: ruleID,
            title: (entry.path as NSString).lastPathComponent,
            detail: L10n.fmt("apps.residue.detail", app.name, L10n.tr(entry.kind.labelKey)),
            path: entry.path,
            category: category,
            risk: entry.kind.risk,
            isDirectory: FileSystem.isDirectory(FileSystem.url(entry.path)),
            bundleID: app.bundleID,
            appKind: .residue(entry.kind),
            appName: app.name,
            holdsLiveAppData: holdsLiveAppData
        )
    }

    /// The app bundle's subtitle: "Version x · N residue files", with missing parts omitted automatically.
    static func appDetail(version: String, residueCount: Int) -> String {
        var parts: [String] = []
        if !version.isEmpty {
            parts.append(L10n.fmt("apps.version", version))
        }
        if residueCount > 0 {
            let key = residueCount == 1 ? "apps.residueSummary.one" : "apps.residueSummary.other"
            parts.append(L10n.fmt(key, residueCount))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Discovery

    /// Enumerate .app bundles under roots and read their Info.plist; skip those
    /// without a bundle ID (broken bundles).
    ///
    /// `com.apple.*` system apps are skipped as well: they cannot be uninstalled
    /// on macOS, and their residue data (containers, application support) is
    /// TCC-protected on macOS 26+, so probing them pops an authorization dialog.
    static func discoverApps(roots: [String]) -> [InstalledApp] {
        var apps: [InstalledApp] = []
        var seenPaths = Set<String>()
        for root in roots {
            for child in FileSystem.children(of: root) {
                guard child.pathExtension.lowercased() == "app" else { continue }
                guard FileSystem.isDirectory(child) else { continue }
                guard seenPaths.insert(child.path).inserted else { continue }
                guard let app = readApp(at: child) else { continue }
                guard !app.bundleID.hasPrefix(FileSystem.systemDataPrefix) else { continue }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func readApp(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url) else { return nil }
        guard let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty else { return nil }
        let info = bundle.infoDictionary ?? [:]
        // Consistent with Finder's naming order: CFBundleDisplayName (the localized
        // display name) comes first, because users recognize the app they want to
        // uninstall by the name shown in Finder.
        let name = nonEmpty(info["CFBundleDisplayName"] as? String)
            ?? nonEmpty(info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = nonEmpty(info["CFBundleShortVersionString"] as? String)
            ?? nonEmpty(info["CFBundleVersion"] as? String)
            ?? ""
        return InstalledApp(name: name, bundleID: bundleID, version: version, path: url.path)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    // MARK: - Residue probing

    /// A probed residue path and its kind.
    struct ResidueEntry: Sendable, Hashable {
        let path: String
        let kind: ResidueKind
    }

    /// Whether a bundle-supplied string can be spliced into a probe path as a
    /// single component.
    ///
    /// The bundle id and the app name are read from the bundle's own
    /// Info.plist, which makes them untrusted input: a bundle directory named
    /// `..app` resolves to the app name "..", and a crafted
    /// `CFBundleIdentifier` can spell `../../Documents`. Spliced into a probe
    /// such as `Library/Application Support/\(id)` those resolve *above* the
    /// probed directory, and the resolved path is what the residue list hands
    /// the uninstall tool as a deletable item — an entire `~/Library` or
    /// `~/Documents` offered as one app's leftovers. Refusing anything that is
    /// not a plain file name keeps every probe inside its own parent.
    static func isSafeComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        // A separator would address a different directory; a control character
        // (NUL included) would truncate the path at the C boundary, so the path
        // deleted would not be the path that was shown.
        if value.contains("/") { return false }
        return value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Probe residue paths across `~/Library` by both bundle ID and app name.
    ///
    /// `home` and `index` are injectable for testing. A nil `index` means
    /// vendor subdirectories are not matched at all — callers that want them
    /// build the index once and pass it in. Only paths that actually exist
    /// are returned; missing locations produce no entries.
    static func residuePaths(
        for app: InstalledApp,
        home: String,
        index: SupportIndex? = nil
    ) -> [ResidueEntry] {
        var found: [ResidueEntry] = []
        var seen = Set<String>()

        // `home` may itself be a symlink (/var → /private/var), so containment
        // is judged against its canonical form.
        let homeRoot = FileSystem.canonical(home)
        // The prefix a contained path must carry. Joined the way
        // `FileSystem.joined` joins a root: for "/" the naive `homeRoot + "/"`
        // would be "//" and match nothing, silently dropping every probe.
        let homePrefix = homeRoot == "/" ? "/" : homeRoot + "/"

        func add(_ relative: String, _ kind: ResidueKind) {
            addAbsolute((home as NSString).appendingPathComponent(relative), kind)
        }

        func addAbsolute(_ rawPath: String, _ kind: ResidueKind) {
            // Canonicalize before deduplicating and checking existence: the paths
            // returned by children() are already resolved by realpath
            // (/var → /private/var), while probe paths assembled from strings are
            // not, so the same directory would become two entries with two spellings.
            let path = FileSystem.canonical(rawPath)
            guard seen.insert(path).inserted else { return }
            guard FileSystem.exists(path) else { return }
            // Backstop for the invariant every probe above depends on: residue
            // lives *under* the home directory, never the home directory
            // itself. Anything that resolved elsewhere — a component that
            // escaped, a symlinked Application Support pointing outside the
            // home tree — is dropped rather than handed to the uninstall tool
            // as a deletable path.
            guard path != homeRoot, path.hasPrefix(homePrefix) else { return }
            found.append(ResidueEntry(path: path, kind: kind))
        }

        // The two probe keys. Both are untrusted (see `isSafeComponent`), so a
        // key that is not a plain file name becomes nil and every probe that
        // uses it is skipped.
        let id: String? = isSafeComponent(app.bundleID) ? app.bundleID : nil
        let name: String? = isSafeComponent(app.name) ? app.name : nil

        if let id { add("Library/Application Support/\(id)", .applicationSupport) }
        if let name { add("Library/Application Support/\(name)", .applicationSupport) }
        // Caches are probed by both bundle ID and app name: bundle authors
        // pick either spelling for `~/Library/Caches` (Chrome uses
        // `Caches/Google/Chrome`, most others `Caches/<bundleID>` or
        // `Caches/<app name>`). Name-based matching is exact-match only —
        // an app called "Chrome" must not claim `Caches/Google` — and safe
        // to be loose about because everything probed here is regenerable.
        if let id { add("Library/Caches/\(id)", .caches) }
        if let name { add("Library/Caches/\(name)", .caches) }
        if let id { add("Library/Containers/\(id)", .containers) }
        if let id { add("Library/Preferences/\(id).plist", .preferences) }
        if let id { add("Library/Saved Application State/\(id).savedState", .savedState) }
        if let id { add("Library/HTTPStorages/\(id)", .httpStorages) }
        if let name { add("Library/HTTPStorages/\(name)", .httpStorages) }
        if let id { add("Library/WebKit/\(id)", .webKit) }
        if let name { add("Library/WebKit/\(name)", .webKit) }
        if let id { add("Library/Cookies/\(id).binarycookies", .cookies) }
        if let id { add("Library/Application Scripts/\(id)", .applicationScripts) }
        if let id { add("Library/LaunchAgents/\(id).plist", .launchAgents) }
        if let id { add("Library/Logs/\(id)", .logs) }
        if let name { add("Library/Logs/\(name)", .logs) }

        // ByHost preferences: ~/Library/Preferences/ByHost/<bundleID>.<UUID>.plist
        if let id {
            let byHost = (home as NSString).appendingPathComponent("Library/Preferences/ByHost")
            for child in FileSystem.children(of: byHost) where child.lastPathComponent.hasPrefix("\(id).") {
                addAbsolute(child.path, .preferences)
            }
        }

        // Crash reports and diagnostic reports are matched by app name prefix.
        // The match must fall on a separator boundary: "X" should not claim
        // "Xcode-….ips" as its own report. An unsafe name matches nothing —
        // `isSafeComponent` has already refused the empty one, which would
        // otherwise match every dotted entry.
        func isReportOf(_ component: String) -> Bool {
            guard let name else { return false }
            return component == name
                || component.hasPrefix(name + "-")
                || component.hasPrefix(name + ".")
        }
        // Skipped entirely without a usable name: two directory listings are
        // not worth running to match nothing.
        if name != nil {
            let crashReporter = (home as NSString).appendingPathComponent("Library/Application Support/CrashReporter")
            for child in FileSystem.children(of: crashReporter) where isReportOf(child.lastPathComponent) {
                addAbsolute(child.path, .crashReports)
            }
            let diagnosticReports = (home as NSString).appendingPathComponent("Library/Logs/DiagnosticReports")
            for child in FileSystem.children(of: diagnosticReports) where isReportOf(child.lastPathComponent) {
                addAbsolute(child.path, .diagnosticReports)
            }
        }

        // Vendor subdirectories (e.g. Application Support/Google/Chrome) are matched via the index
        if let index, let name {
            for path in index.paths(matching: name) { add(path, .applicationSupport) }
        }

        return found
    }

    // MARK: - Application Support index

    /// A shallow name index of `~/Library/Application Support`.
    ///
    /// Many apps put their data in vendor subdirectories (`Google/Chrome`,
    /// `Adobe/…`), which direct probing by bundle ID and app name does not
    /// cover, so a traversal of Application Support at depth ≤2 builds an
    /// index shared by all apps.
    ///
    /// Matching requires every word of the app name to appear **consecutively**
    /// in the path: "Google Chrome" hits `Google/Chrome`; a single word only
    /// hits a same-named top-level directory (`Application Support/Chrome`) —
    /// vendor subdirectories are not guessed, otherwise an app named "Chrome"
    /// would claim Google's data as its own residue.
    struct SupportIndex: Sendable {
        private let entries: [(components: [String], path: String)]

        init(entries: [(components: [String], path: String)]) {
            self.entries = entries
        }

        func paths(matching name: String) -> [String] {
            let words = name.lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard !words.isEmpty else { return [] }

            if words.count == 1 {
                let word = words[0]
                return entries.filter { $0.components.count == 1 && $0.components[0] == word }.map(\.path)
            }
            return entries.filter { entry in
                entry.components.containsConsecutive(words)
            }.map(\.path)
        }
    }

    static func supportIndex(home: String) -> SupportIndex {
        var entries: [(components: [String], path: String)] = []
        let root = (home as NSString).appendingPathComponent("Library/Application Support")
        // Breadth-first: the first level is each app/vendor directory, the second level is product directories under vendors
        var frontier = FileSystem.children(of: root).map { ($0, 1) }
        while !frontier.isEmpty {
            let (url, depth) = frontier.removeFirst()
            guard FileSystem.isDirectory(url) else { continue }
            entries.append((relativeComponents(of: url), url.path))
            if depth < 2 {
                frontier.append(contentsOf: FileSystem.children(of: url.path).map { ($0, depth + 1) })
            }
        }
        return SupportIndex(entries: entries)
    }

    /// The index stores only path components relative to
    /// `Application Support` (lowercased): matching is done by components, and
    /// the prefix of an absolute path is meaningless for matching.
    private static func relativeComponents(of url: URL) -> [String] {
        var components = url.pathComponents.filter { $0 != "/" }
        // Drop the "Library/Application Support" prefix and everything before it, keeping only the relative part
        if let index = components.lastIndex(where: { $0 == "Application Support" }) {
            components = Array(components.dropFirst(index + 1))
        }
        return components.map { $0.lowercased() }
    }
}

/// Whether a given subsequence appears consecutively in the component sequence.
private extension Array where Element == String {
    func containsConsecutive(_ subsequence: [String]) -> Bool {
        guard !subsequence.isEmpty, count >= subsequence.count else { return false }
        outer: for start in 0...(count - subsequence.count) {
            for offset in 0..<subsequence.count where self[start + offset] != subsequence[offset] {
                continue outer
            }
            return true
        }
        return false
    }
}
