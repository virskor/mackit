import Foundation

/// Discovery of cache directories that no installed app claims — what is
/// left behind after an app was dragged to the Trash instead of being
/// uninstalled properly.
///
/// The pool design: enumerate the shared cache trees once, subtract everything
/// an installed app or a static rule already covers, and report only the
/// remainder.
/// Subtracting claims rather than adding a catch-all rule is what keeps the
/// broad sweep honest — the dedicated browser / IDE rules and the per-app
/// residue scan keep their paths, and only the unclaimed ones become items,
/// so no byte is counted twice.
///
/// Which direction to err in is forced by what the entries are: offering a
/// live app's cache for deletion is a bug, while a missed leftover is only a
/// missed cleanup. The matching is therefore wider than
/// `AppScanner.residuePaths` (exact bundle id, exact app name, last
/// dot-segment): a pool entry whose name carries an installed app's bundle
/// id at a dot boundary — prefixed, suffixed or team-prefixed — is claimed
/// too, because `com.spotify.client.helper` is Spotify's cache and not an
/// orphan. Every item is `.review`: an unclaimed cache cannot be
/// re-attributed to the app that made it, so the user decides.
///
/// Known limitation, shared with the residue scan: apps are discovered
/// under `/Applications` and `~/Applications` only (`AppScanner.defaultRoots`),
/// so an app installed elsewhere keeps its caches claimed by nothing. The
/// entries are regenerable caches, and the `.review` level keeps them out of
/// every default selection.
enum LeftoverCacheScanner {
    /// Rule id shared by every leftover entry.
    static let ruleID = "app.leftover"

    /// Cache names excluded regardless of ownership.
    ///
    /// Their caches hold user assets — offline libraries, playback state —
    /// rather than regenerable bytes. Once the owning app is gone there is no
    /// bundle id left to match on, so the name is the only handle that remains.
    static let protectedNames: Set<String> = ["1Password", "IINA"]

    /// Mackit's own bundle ids: a running cleaner's cache must never be
    /// offered as junk. The agent is a separate process with its own id, so
    /// both are listed.
    static let selfBundleIDs: Set<String> = ["cn.mingcui.mackit", "cn.mingcui.mackit.agent"]

    /// Enumerate the cache pools and report every entry no installed app
    /// and no static rule claims.
    ///
    /// `rules` is injectable for testing; production callers take the whole
    /// catalog so a rule that digs into a pool keeps its paths claimed.
    static func scanLeftoverCaches(
        roots: [String] = AppScanner.defaultRoots,
        home: String = NSHomeDirectory(),
        rules: [ScanRule] = RulesCatalog.scanRules
    ) -> [JunkItem] {
        let claims = ClaimSet(apps: AppScanner.discoverApps(roots: roots), rules: rules)
        var found: [JunkItem] = []
        var seen = Set<String>()

        // Pool 1: the user cache root. `com.apple.*` system data is skipped
        // by the listing itself (see `FileSystem.systemDataPrefix`).
        for entry in entries(of: (home as NSString).appendingPathComponent("Library/Caches")) {
            add(entry, claims: claims, to: &found, seen: &seen)
        }

        // Pool 2: caches inside sandbox containers whose owning app is gone.
        // A container is named after its app's bundle id, so an unclaimed
        // dot-named container is an orphan. UUID-named group containers are
        // shared by installed apps and claimed by no single one, so they are
        // never orphan candidates.
        let containers = entries(of: (home as NSString).appendingPathComponent("Library/Containers"))
        for container in containers where container.isDirectory && container.name.contains(".") {
            guard !claims.contains(container.name), !claims.claimsPath(container.path) else { continue }
            let caches = FileSystem.joined("Data/Library/Caches", in: container.path)
            for entry in entries(of: caches) {
                add(entry, claims: claims, to: &found, seen: &seen)
            }
        }

        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Appends one pool entry unless something already owns it.
    private static func add(
        _ entry: FileSystem.DirectoryEntry,
        claims: ClaimSet,
        to found: inout [JunkItem],
        seen: inout Set<String>
    ) {
        let name = entry.name
        // Reverse-DNS style only: vendor buckets without a dot (Google,
        // Mozilla) hold several products' caches and are never one app's
        // leftover.
        guard name.contains(".") else { return }
        guard !protectedNames.contains(name), !selfBundleIDs.contains(name) else { return }
        guard !claims.contains(name) else { return }
        let path = FileSystem.joined(name, in: entry.parentPath)
        // A rule that targets this path directly, sits inside it, or is
        // reached through it has already claimed these bytes.
        guard !claims.claimsPath(path) else { return }
        guard seen.insert(path).inserted else { return }
        found.append(
            JunkItem(
                ruleID: ruleID,
                title: name,
                detail: L10n.tr("apps.leftover.detail"),
                path: path,
                category: .appJunk,
                risk: .review,
                isDirectory: entry.isDirectory,
                // A cache is rebuilt on demand, so deleting one never pulls
                // live data out from under a process (see JunkItem).
                holdsLiveAppData: false
            )
        )
    }

    /// The pool's entries, empty when the directory cannot be read.
    private static func entries(of path: String) -> [FileSystem.DirectoryEntry] {
        FileSystem.entries(of: path) ?? []
    }

    // MARK: - Claims

    /// Everything that already owns a path in the pools: the installed apps,
    /// by the names their caches are spelled with, and the static rules, by
    /// the literal prefixes of their targets.
    struct ClaimSet {
        /// App-claimed cache names, lowercased: bundle ids, app names, and
        /// each bundle id's last dot-segment (`com.bohemiancoding.sketch3`
        /// claims `sketch3`). Lowercased because APFS preserves the case a
        /// cache directory was created with, while the bundle id's own case
        /// is whatever the developer typed.
        private let appNames: Set<String>
        /// The installed apps' bundle ids, lowercased, for the
        /// dot-bounded match in `contains`. An exact-name claim alone
        /// misses the extremely common suffixed spellings —
        /// `com.spotify.client.helper` and `com.microsoft.VSCode.ShipIt`
        /// are caches of installed apps, not leftovers of removed ones.
        private let bundleIDs: [String]
        /// Every static rule's literal target prefix, expanded but *not*
        /// canonicalized: pool paths are spelled the same way — joined under
        /// the home directory as expanded — and canonicalizing one side only
        /// would make the two never match on a firmlinked home (`/Users` vs
        /// `/System/Volumes/Data/Users`).
        private let rulePrefixes: [String]

        init(apps: [InstalledApp], rules: [ScanRule] = RulesCatalog.scanRules) {
            var names = Set<String>()
            var ids: [String] = []
            for app in apps {
                // The same guard the residue probes apply to untrusted
                // Info.plist values (see `AppScanner.isSafeComponent`); here
                // the name is only matched, never spliced into a path.
                if AppScanner.isSafeComponent(app.bundleID) {
                    let id = app.bundleID.lowercased()
                    ids.append(id)
                    names.insert(id)
                    if let last = app.bundleID.split(separator: ".").last {
                        names.insert(last.lowercased())
                    }
                }
                if AppScanner.isSafeComponent(app.name) {
                    names.insert(app.name.lowercased())
                }
            }
            self.appNames = names
            self.bundleIDs = ids
            self.rulePrefixes = rules.compactMap { rule -> String? in
                let prefix = rule.targetLiteralPrefix
                guard !prefix.isEmpty else { return nil }
                return FileSystem.expand(prefix)
            }
        }

        /// Whether an installed app claims this cache name.
        ///
        /// The exact match covers the direct spellings; the dot-bounded
        /// bundle-id relations cover the suffixed and team-prefixed
        /// spellings the pools are full of:
        ///
        /// - `com.spotify.client.helper` — a helper's cache, claimed by
        ///   the app's own bundle id as a prefix;
        /// - `88L2Q4487U.com.tencent.WeWorkMac.IPCHelper` — a
        ///   team-prefixed sandbox container, claimed by the bundle id
        ///   as a contained segment run.
        ///
        /// Claiming too much costs a missed cleanup; claiming too little
        /// offers a live app's cache for deletion, which is the direction
        /// this scanner's contract forbids.
        func contains(_ name: String) -> Bool {
            let lower = name.lowercased()
            if appNames.contains(lower) { return true }
            for id in bundleIDs {
                if lower.hasPrefix(id + ".") { return true }
                if lower.hasSuffix("." + id) { return true }
                if lower.contains("." + id + ".") { return true }
            }
            return false
        }

        /// Whether any static rule already covers this path — as the rule's
        /// own target, an ancestor of it (`Google` above
        /// `Google/Chrome*/*/Cache`), or a descendant of it (a rule that
        /// digs into the pool entry, such as `Caches/CocoaPods`).
        func claimsPath(_ path: String) -> Bool {
            rulePrefixes.contains { prefix in
                path == prefix || path.hasPrefix(prefix + "/") || prefix.hasPrefix(path + "/")
            }
        }
    }
}
