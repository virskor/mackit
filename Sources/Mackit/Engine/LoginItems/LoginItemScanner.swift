import Foundation

/// One startup item found on the system.
///
/// The four kinds cover every way software registers itself to start
/// automatically that a third-party app can see and manage on macOS 14+:
/// per-user launch agents, machine-wide launch agents (which load into
/// each user's session), machine-wide launch daemons (which need the
/// privileged helper to change), and the legacy login items list.
///
/// The fifth way — an app's own `Contents/Library/LoginItems` helper —
/// is deliberately absent: since macOS 13 only the owning app itself may
/// manage those, so there is nothing a cleaner can toggle.
struct LoginItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// `~/Library/LaunchAgents` — the current user's own agents.
        case userAgent
        /// `/Library/LaunchAgents` — every user's agents; the current
        /// user holds the override for their own session.
        case globalAgent
        /// `/Library/LaunchDaemons` — system services; changing them
        /// goes through the privileged helper.
        case systemDaemon
        /// The legacy login items list — presence is the enabled state.
        case legacyLoginItem
    }

    /// Stable identity: the plist's path for agents and daemons, the
    /// target's path for a legacy login item.
    let id: String
    let kind: Kind
    /// The launchd label; for a legacy item, the target's file name.
    let label: String
    /// The plist on disk — nil for legacy login items.
    let plistPath: String?
    /// The app or binary the item runs, when the plist or the list entry
    /// names one.
    let targetPath: String?
    /// The installed app this item was matched to, when any. Drives the
    /// row's icon and name and the per-app grouping.
    let app: MatchedApp?
    /// Whether the item will start at login (or at boot for daemons).
    /// Backed by launchd's override database, so it survives reboots.
    var isEnabled: Bool

    /// Whether changing this item requires the privileged helper.
    var needsHelper: Bool { kind == .systemDaemon }
}

/// The app a startup item was matched to.
struct MatchedApp: Equatable, Sendable {
    let name: String
    let path: String
}

/// A startup item and its per-app peers — the unit the page lists.
///
/// Items that belong to the same installed app group under it (the
/// agent's icon and name, one master switch); items with no app match
/// group alone under their own label, so every listed row still has a
/// name and a switch.
struct LoginItemGroup: Identifiable, Equatable, Sendable {
    /// The app's bundle path when matched, otherwise "label:" plus the
    /// item's label.
    let id: String
    let app: MatchedApp?
    var items: [LoginItem]

    var name: String { app?.name ?? (items.first?.label ?? "") }
    var iconPath: String? { app?.path }

    /// How many of the group's items are enabled.
    var enabledCount: Int { items.count(where: \.isEnabled) }

    /// The group's aggregate state — the status pill's three states.
    var status: Status {
        if enabledCount == 0 { return .allDisabled }
        if enabledCount == items.count { return .allEnabled }
        return .partial
    }

    enum Status: Equatable, Sendable {
        case allEnabled
        case partial
        case allDisabled
    }
}

/// How the page sorts its groups.
enum LoginItemSort: String, CaseIterable, Identifiable, Sendable {
    case name
    case status

    var id: String { rawValue }
}

/// Discovers the system's startup items.
///
/// The scan is three directory listings, two `launchctl` state queries
/// and one legacy-list snapshot — all injected, so the parsing and
/// grouping (the parts with logic worth testing) run against fixtures
/// while the defaults do the real thing.
///
/// The enabled state comes from launchd's override database
/// (`print-disabled`), not from whether a service is currently running:
/// a service that is loaded but disabled reads as disabled, which is the
/// state that decides the next login — the question this tool answers.
enum LoginItemScanner {
    /// The three launchd directories, with the kind each one's plists
    /// get. Order is the display order of the kinds.
    static let scanDirectories: [(kind: LoginItem.Kind, path: String)] = [
        (.userAgent, FileSystem.expand("~/Library/LaunchAgents")),
        (.globalAgent, "/Library/LaunchAgents"),
        (.systemDaemon, "/Library/LaunchDaemons")
    ]

    /// Mackit's own startup items — the tray agent's login item and the
    /// privileged helper's daemon — are filtered out. Listing them would
    /// invite the user to switch off the app's own infrastructure, and
    /// the helper has its own dedicated remove action.
    static let ownBundleID = "cn.mingcui.mackit"

    /// Whether a label belongs to Mackit itself.
    static func isOwnItem(_ label: String) -> Bool {
        label == ownBundleID || label.hasPrefix(ownBundleID + ".")
    }

    // MARK: - Scan

    /// Runs a full scan with the production seams.
    ///
    /// `directories` is injectable the same way `AppScanner`'s roots
    /// are: the default is the three real launchd directories, and a
    /// test points the scan at fixture trees.
    static func scan(
        directories: [(kind: LoginItem.Kind, path: String)] = scanDirectories,
        launchctl: @escaping LaunchctlRun = { arguments in await LaunchctlRunner.run(arguments) },
        apps: [InstalledApp] = AppScanner.discoverApps(roots: AppScanner.defaultRoots),
        legacyItems: [LegacyLoginItems.Item] = LegacyLoginItems.snapshot()
    ) async -> [LoginItem] {
        let uid = getuid()
        // Two queries, not one per item: the override database is dumped
        // whole and parsed here. A missing answer (launchctl failed) is
        // an empty map, and every label then reads as enabled — the
        // default state with no override recorded. The two dumps are
        // independent, so they run concurrently.
        async let userOutput = launchctl(["print-disabled", "gui/\(uid)"])
        async let systemOutput = launchctl(["print-disabled", "system"])
        let userStates = parseDisabledStates(await userOutput)
        let systemStates = parseDisabledStates(await systemOutput)

        var items: [LoginItem] = []
        for (kind, directory) in directories {
            let states = kind == .systemDaemon ? systemStates : userStates
            items.append(contentsOf: plistItems(in: directory, kind: kind, apps: apps, states: states))
        }
        items.append(contentsOf: legacyLoginItems(legacyItems, apps: apps))
        return items
    }

    /// The plist-backed items in one directory.
    private static func plistItems(
        in directory: String,
        kind: LoginItem.Kind,
        apps: [InstalledApp],
        states: [String: Bool]
    ) -> [LoginItem] {
        // FileSystem.entries is the codebase's enumeration entry point:
        // it reports an unreadable directory as nil (skipped, logged),
        // skips com.apple.* system entries, and costs no per-file
        // attribute reads.
        guard let entries = FileSystem.entries(of: directory) else { return [] }
        var items: [LoginItem] = []
        for entry in entries {
            guard !entry.isDirectory else { continue }
            guard entry.name.hasSuffix(".plist") else { continue }
            let path = entry.url.path
            guard let info = parsePlist(at: path) else { continue }
            guard !isOwnItem(info.label) else { continue }
            items.append(
                LoginItem(
                    id: path,
                    kind: kind,
                    label: info.label,
                    plistPath: path,
                    targetPath: info.programPath,
                    app: matchApp(label: info.label, programPath: info.programPath, apps: apps),
                    // A label with no override is enabled; launchd's own
                    // default, and the safe reading of a failed dump.
                    isEnabled: states[info.label] ?? true
                )
            )
        }
        return items
    }

    /// The legacy login items, as items whose presence is their state.
    private static func legacyLoginItems(
        _ entries: [LegacyLoginItems.Item],
        apps: [InstalledApp]
    ) -> [LoginItem] {
        entries.compactMap { entry in
            // An entry whose target is one of Mackit's own bundles is
            // filtered the same way the plists are: the tray agent's
            // login item must not be switchable from this page.
            if let bundleID = Bundle(url: URL(fileURLWithPath: entry.path))?.bundleIdentifier,
               isOwnItem(bundleID) {
                return nil
            }
            let fallbackName = URL(fileURLWithPath: entry.path).lastPathComponent
            return LoginItem(
                id: "legacy:\(entry.path)",
                kind: .legacyLoginItem,
                label: entry.displayName ?? fallbackName,
                plistPath: nil,
                targetPath: entry.path,
                app: matchApp(label: entry.displayName ?? "", programPath: entry.path, apps: apps),
                isEnabled: true
            )
        }
    }

    // MARK: - Parsing

    /// The parsed contents of one launchd plist: its label (required —
    /// launchd itself refuses a plist without one) and the program it
    /// runs (the first ProgramArguments entry, when present).
    struct PlistInfo: Equatable, Sendable {
        let label: String
        let programPath: String?
    }

    /// Reads one plist defensively: a hand-mangled file (an array where
    /// a dictionary belongs, a missing Label, a non-string Program) is
    /// skipped rather than trusted. A plist the user edited into
    /// nonsense is not a startup item anyone can manage.
    static func parsePlist(at path: String) -> PlistInfo? {
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
        guard let label = dict["Label"] as? String, !label.isEmpty else { return nil }
        var programPath: String?
        if let arguments = dict["ProgramArguments"] as? [Any], let first = arguments.first {
            programPath = first as? String
        } else if let program = dict["Program"] as? String {
            programPath = program
        }
        return PlistInfo(label: label, programPath: programPath)
    }

    /// Parses `launchctl print-disabled` output into label → enabled.
    ///
    /// The output is a dictionary dump whose lines read
    /// `"com.example.Service" => disabled`. A label with no line has no
    /// override and is enabled, so it is absent from the result — the
    /// caller applies the default. The value is compared as a whole
    /// token, not by substring: a label containing the word "disabled"
    /// must not be able to flip its own state.
    static func parseDisabledStates(_ output: String?) -> [String: Bool] {
        guard let output else { return [:] }
        var states: [String: Bool] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let label = labelFromDisabledLine(line) else { continue }
            let parts = line.split(separator: "=>", maxSplits: 1)
            guard parts.count == 2 else { continue }
            states[label] = parts[1].trimmingCharacters(in: .whitespaces) != "disabled"
        }
        return states
    }

    /// The quoted label of one `"label" => value` line, or nil when the
    /// line is not of that shape (the header and closing brace are not).
    private static func labelFromDisabledLine(_ line: String) -> String? {
        guard line.hasPrefix("\"") else { return nil }
        let rest = line.dropFirst()
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let label = String(rest[..<end])
        return label.isEmpty ? nil : label
    }

    // MARK: - App matching

    /// Matches an item to the app it belongs to.
    ///
    /// The program path wins when it points inside an app bundle — that
    /// is the binary actually being run, whether or not the app sits in
    /// an Applications folder. Otherwise the label is matched against
    /// the installed apps' bundle IDs: launchd labels are conventionally
    /// the bundle ID (sometimes with a suffix), so a containment test
    /// recovers the app from the label alone.
    static func matchApp(label: String, programPath: String?, apps: [InstalledApp]) -> MatchedApp? {
        if let programPath, let bundleRoot = appBundleRoot(of: programPath) {
            return MatchedApp(name: appName(ofPath: bundleRoot), path: bundleRoot)
        }
        let loweredLabel = label.lowercased()
        for app in apps where !app.bundleID.isEmpty {
            if loweredLabel.contains(app.bundleID.lowercased()) {
                return MatchedApp(name: app.name, path: app.path)
            }
        }
        return nil
    }

    /// The `.app` bundle root of a path that runs from inside one, or
    /// nil. The first `.app` component from the left is the root: a
    /// helper at `Foo.app/Contents/Library/LoginItems/Bar.app` is still
    /// Foo's helper for grouping purposes.
    private static func appBundleRoot(of path: String) -> String? {
        guard let range = path.range(of: ".app") else { return nil }
        let root = String(path[path.startIndex..<range.upperBound])
        // The remainder must be a path separator or nothing: a file
        // literally named "x.appliance" is not a bundle.
        let remainder = path[range.upperBound...]
        guard remainder.isEmpty || remainder.hasPrefix("/") else { return nil }
        return root
    }

    /// An app bundle's display name: the file name without its
    /// extension. The plist's own display name is deliberately not read
    /// here — the group's name only needs to be recognizable, and the
    /// installed-app match already carries the real one when there is
    /// one.
    private static func appName(ofPath path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    // MARK: - Grouping and sorting

    /// Groups items by their matched app, unmatched items grouping
    /// alone under their own label. Groups sort by name, or by status
    /// (enabled first, then partial, then disabled) with name breaking
    /// ties.
    static func group(_ items: [LoginItem], sort: LoginItemSort = .name) -> [LoginItemGroup] {
        var groupsByID: [String: LoginItemGroup] = [:]
        var order: [String] = []
        for item in items {
            if let app = item.app {
                let key = "app:\(app.path)"
                if groupsByID[key] == nil { order.append(key) }
                groupsByID[key, default: LoginItemGroup(id: key, app: app, items: [])].items.append(item)
            } else {
                let key = "label:\(item.label)"
                if groupsByID[key] == nil { order.append(key) }
                groupsByID[key, default: LoginItemGroup(id: key, app: nil, items: [])].items.append(item)
            }
        }
        var groups = order.compactMap { groupsByID[$0] }
        switch sort {
        case .name:
            groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .status:
            groups.sort { lhs, rhs in
                if lhs.status != rhs.status {
                    return statusRank(lhs.status) < statusRank(rhs.status)
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        return groups
    }

    /// The status sort order: enabled groups first, disabled last.
    private static func statusRank(_ status: LoginItemGroup.Status) -> Int {
        switch status {
        case .allEnabled: return 0
        case .partial: return 1
        case .allDisabled: return 2
        }
    }

    /// The groups matching `search`, or all of them for an empty
    /// search. A group matches when any of its items matches — the app
    /// name, the label, the target path or the plist path — so a search
    /// for a bundle ID finds the group through one of its entries.
    static func filter(_ groups: [LoginItemGroup], search: String) -> [LoginItemGroup] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.filter { group in
            if group.name.lowercased().contains(needle) { return true }
            return group.items.contains { item in
                item.label.lowercased().contains(needle)
                    || item.targetPath?.lowercased().contains(needle) == true
                    || item.plistPath?.lowercased().contains(needle) == true
                    || item.app?.path.lowercased().contains(needle) == true
            }
        }
    }
}
