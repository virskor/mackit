import Foundation

/// One installed Homebrew package: a formula (Cellar) or a cask (an app).
///
/// The detail fields mirror what `brew info --json=v2` reports for an
/// installed package — description, versions, install date, dependencies,
/// license, tap — so the manager page can show the same facts a terminal
/// user would look up, without scraping human-readable output.
struct HomebrewPackage: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case formula
        case cask

        /// The `brew` subcommand flag for this kind.
        var commandFlag: String { self == .formula ? "--formula" : "--cask" }

        /// The tag's localized title, shown beside a package's name in the
        /// list rows and the detail header.
        var tagTitle: String {
            L10n.tr(self == .formula ? "homebrew.kind.formula" : "homebrew.kind.cask")
        }
    }

    /// Formula name or cask token — what every brew subcommand takes.
    let name: String
    /// Casks carry a display name ("Codex") besides their token; formulae
    /// use their name.
    let displayName: String
    let kind: Kind

    let installedVersion: String
    /// The latest version in the local index; nil when unknown.
    let latestVersion: String?
    let isOutdated: Bool

    let description: String?
    let homepage: String?
    let license: String?
    /// The tap the package came from, e.g. "homebrew/core".
    let tap: String?
    /// Declared runtime dependencies, by name.
    let dependencies: [String]
    /// When this version was installed, from the Cellar receipt.
    let installedAt: Date?
    /// True when the user asked for it directly, false when it was pulled
    /// in as a dependency — brew's own distinction.
    let installedOnRequest: Bool?
    /// True when installed from a prebuilt bottle rather than built from
    /// source.
    let pouredFromBottle: Bool?
    let pinned: Bool

    /// On-disk size for formulae (the Cellar directory); nil for casks,
    /// whose payload lands in /Applications and is not owned by the prefix.
    var size: Int64?

    var id: String { "\(kind.rawValue)/\(name)" }

    var upgradeCommand: String { "brew upgrade \(kind.commandFlag) \(name)" }
    var uninstallCommand: String { "brew uninstall \(kind.commandFlag) \(name)" }

    func withSize(_ size: Int64) -> HomebrewPackage {
        var copy = self
        copy.size = size
        return copy
    }
}

/// Everything the manager page shows about one Homebrew installation.
struct HomebrewSnapshot: Equatable, Sendable {
    /// Absolute path of the `brew` executable that answered.
    let brewPath: String
    /// `brew --version`'s first line, e.g. "4.4.15". Nil when the call fails.
    let version: String?
    /// Installation prefix, e.g. "/opt/homebrew".
    let prefix: String
    /// Download cache (`brew --cache`) and how much of it is on disk.
    let cachePath: String
    let cacheSize: Int64
    /// Cellar (`brew --cellar`) and its total size.
    let cellarPath: String
    let cellarSize: Int64

    let formulae: [HomebrewPackage]
    let casks: [HomebrewPackage]

    /// False when the JSON detail query failed and only names + versions are
    /// known — the page degrades to a plain list and says so, rather than
    /// presenting half a detail pane.
    let detailsAvailable: Bool

    var allPackages: [HomebrewPackage] { formulae + casks }
    var outdated: [HomebrewPackage] { allPackages.filter(\.isOutdated) }

    /// False when brew answered but produced nothing usable — a broken or
    /// half-installed setup — so the page can say so instead of presenting an
    /// empty installation as a real one.
    var isUsable: Bool {
        version != nil || !formulae.isEmpty || !casks.isEmpty
    }
}

/// Reads one Homebrew installation: where it lives, what it has installed,
/// and what is out of date.
///
/// Every subprocess goes through the injected `run` closure, so the whole
/// inspector is testable against canned `brew` output; only the directory
/// measurements touch the real filesystem, and those read fixture paths the
/// canned output points at.
///
/// The detail fields come from `brew info --json=v2`, one bulk call for all
/// formulae and one for all casks. The JSON shapes below were verified
/// against brew 7.x; json=v2 itself has been stable since brew 2.1, well
/// below anything a macOS 14 user realistically runs.
typealias BrewCommand = @Sendable ([String], Duration) async -> String?

/// The streaming counterpart of `BrewCommand`: runs an action and reports each
/// output line as it arrives, for the progress the page shows while brew works.
///
/// The callback is main-actor isolated because it drives observable page state;
/// the runner calls it from its pipe readers, which is why it is `@Sendable`.
typealias BrewStreamCommand = @Sendable ([String], Duration, @escaping @MainActor @Sendable (String) -> Void) async -> String?

enum HomebrewInspector {
    /// Queries a full snapshot. Returns nil only when brew is not installed.
    ///
    /// `brewPath` defaults to the real lookup; tests inject a fake path so
    /// the merge and parsing logic runs on machines without Homebrew.
    static func inspect(
        brewPath: String? = nil,
        run: BrewCommand = HomebrewRunner.run
    ) async -> HomebrewSnapshot? {
        guard let brewPath = brewPath ?? ToolLocator.resolve("brew") else {
            MackitLog.brew.info("homebrew not installed")
            return nil
        }

        func read(_ arguments: [String]) async -> String? {
            await run(arguments, readTimeout)
        }

        // Sequential, not a task group: brew takes locks for writes, and each
        // read is a few hundred milliseconds — parallel buys nothing, while
        // serial keeps the ordering deterministic for logging.
        let version = parseVersion(await read(["--version"]) ?? "")
        let prefix = (await read(["--prefix"])) ?? defaultPrefix
        let cachePath = (await read(["--cache"])) ?? "\(NSHomeDirectory())/Library/Caches/Homebrew"
        let cellarPath = (await read(["--cellar"])) ?? "\(prefix)/Cellar"

        let listedFormulae = parseList(await read(["list", "--versions"]) ?? "", kind: .formula)
        let listedCasks = parseList(await read(["list", "--cask", "--versions"]) ?? "", kind: .cask)

        // Details arrive as one bulk JSON call per kind. A failure (an old
        // brew without json=v2, or a stale index naming a removed formula)
        // degrades the page to the name+version list, which is still
        // actionable — it just cannot show descriptions or dependencies.
        let detailsAvailable: Bool
        var formulae = listedFormulae
        var casks = listedCasks
        // An empty name list skips the call outright: `brew info --json=v2`
        // with no arguments answers with the whole index (verified on brew
        // 7.x — thousands of entries), and zero packages have nothing to
        // enrich, so they are vacuously fully known.
        if listedFormulae.isEmpty {
            detailsAvailable = true
        } else if let infoJSON = await read(["info", "--json=v2"] + listedFormulae.map(\.name)) {
            let details = parseInfoJSON(infoJSON, kind: .formula)
            if details.isEmpty {
                // A decodable but empty payload means the call failed in a
                // way JSON cannot express (brew prints the error to stderr
                // and exits nonzero) — treat it as no details.
                detailsAvailable = false
            } else {
                formulae = merge(list: listedFormulae, details: details, kind: .formula)
                detailsAvailable = true
            }
        } else {
            detailsAvailable = false
        }
        if !listedCasks.isEmpty, let caskJSON = await read(["info", "--cask", "--json=v2"] + listedCasks.map(\.name)) {
            casks = merge(list: listedCasks, details: parseInfoJSON(caskJSON, kind: .cask), kind: .cask)
        }

        let snapshot = HomebrewSnapshot(
            brewPath: brewPath,
            version: version,
            prefix: prefix,
            cachePath: cachePath,
            cacheSize: size(of: cachePath),
            cellarPath: cellarPath,
            cellarSize: size(of: cellarPath),
            formulae: withFormulaSizes(formulae, cellarPath: cellarPath),
            casks: casks,
            detailsAvailable: detailsAvailable
        )
        MackitLog.brew.info(
            "inspected \(brewPath, privacy: .public): \(formulae.count, privacy: .public) formulae, \(casks.count, privacy: .public) casks, \(snapshot.outdated.count, privacy: .public) outdated, cache \(snapshot.cacheSize, privacy: .public) bytes, cellar \(snapshot.cellarSize, privacy: .public) bytes"
        )
        return snapshot
    }

    /// Fallback prefix when `brew --prefix` itself fails: Apple Silicon first,
    /// since that is where Homebrew installs on any supported machine.
    private static let defaultPrefix = "/opt/homebrew"

    /// Timeout for every read query. A hung `brew list` is useless long
    /// before this, and the page refreshes on demand anyway.
    private static let readTimeout: Duration = .seconds(120)

    // MARK: - Text parsing

    /// "Homebrew 4.4.15" → "4.4.15". `brew --version` prints a second line
    /// (the core tap's git revision); only the first line matters here.
    static func parseVersion(_ output: String) -> String? {
        guard let first = output.split(separator: "\n").first else { return nil }
        let line = first.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("Homebrew ") else { return line.isEmpty ? nil : line }
        let version = line.dropFirst("Homebrew ".count).trimmingCharacters(in: .whitespaces)
        return version.isEmpty ? nil : version
    }

    /// Parses `brew list --versions` / `brew list --cask --versions`:
    /// "wget 1.21.4", "node 20.11.0 18.19.0" (several installed versions side
    /// by side) and tap-qualified names like "homebrew/cask/firefox".
    static func parseList(_ output: String, kind: HomebrewPackage.Kind) -> [HomebrewPackage] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let name = fields.first, let version = fields.dropFirst().first else { return nil }
            return HomebrewPackage(
                name: String(name),
                displayName: String(name),
                kind: kind,
                installedVersion: String(version),
                latestVersion: nil,
                isOutdated: false,
                description: nil,
                homepage: nil,
                license: nil,
                tap: nil,
                dependencies: [],
                installedAt: nil,
                installedOnRequest: nil,
                pouredFromBottle: nil,
                pinned: false,
                size: nil
            )
        }
    }

    // MARK: - JSON details

    /// Decodes a `brew info --json=v2` payload into kind-neutral details.
    /// Internal so tests can feed it canned payloads; the inspector calls it
    /// once per kind. An undecodable payload yields an empty array — the
    /// caller treats that as "details unavailable".
    static func parseInfoJSON(_ json: String, kind: HomebrewPackage.Kind) -> [BrewDetail] {
        guard let info = try? JSONDecoder().decode(BrewInfo.self, from: Data(json.utf8)) else { return [] }
        switch kind {
        case .formula: return (info.formulae ?? []).map(\.detail)
        case .cask: return (info.casks ?? []).compactMap(\.detail)
        }
    }

    // MARK: - Merging & measuring

    /// Folds the JSON details into the listed packages. The list stays the
    /// source of truth for what is installed; details only enrich what the
    /// list already has — a detail entry for an uninstalled package is
    /// dropped rather than resurrecting it.
    private static func merge(
        list: [HomebrewPackage],
        details: [BrewDetail],
        kind: HomebrewPackage.Kind
    ) -> [HomebrewPackage] {
        var byName: [String: BrewDetail] = [:]
        for detail in details where byName[detail.name] == nil {
            byName[detail.name] = detail
        }
        return list.map { package in
            guard let detail = byName[package.name] else { return package }
            return HomebrewPackage(
                name: package.name,
                displayName: detail.displayName ?? package.name,
                kind: kind,
                installedVersion: detail.installedVersion ?? package.installedVersion,
                latestVersion: detail.latestVersion,
                isOutdated: detail.isOutdated,
                description: detail.description,
                homepage: detail.homepage,
                license: detail.license,
                tap: detail.tap,
                dependencies: detail.dependencies,
                installedAt: detail.installedAt,
                installedOnRequest: detail.installedOnRequest,
                pouredFromBottle: detail.pouredFromBottle,
                pinned: detail.pinned,
                size: package.size
            )
        }
    }

    /// Folds each formula's measured Cellar size into the list. Separated out
    /// so the traversal stays a single pass over the Cellar's children.
    static func withFormulaSizes(_ packages: [HomebrewPackage], cellarPath: String) -> [HomebrewPackage] {
        let cellar = URL(fileURLWithPath: cellarPath, isDirectory: true)
        return packages.map { package in
            package.withSize(size(of: cellar.appendingPathComponent(package.name).path))
        }
    }

    private static func size(of path: String) -> Int64 {
        FileSystem.allocatedSize(ofPath: path)
    }
}

// MARK: - JSON shapes (verified against brew 7.x output)

/// `brew info --json=v2` payload: both kinds can appear in one response.
private struct BrewInfo: Decodable {
    let formulae: [BrewFormulaDetail]?
    let casks: [BrewCaskDetail]?
}

/// The kind-neutral detail both JSON shapes bridge into.
struct BrewDetail {
    let name: String
    let displayName: String?
    let installedVersion: String?
    let latestVersion: String?
    let isOutdated: Bool
    let description: String?
    let homepage: String?
    let license: String?
    let tap: String?
    let dependencies: [String]
    let installedAt: Date?
    let installedOnRequest: Bool?
    let pouredFromBottle: Bool?
    let pinned: Bool
}

/// One formula's details, reduced to what the page shows. Every field is
/// optional: a formula mid-deprecation or without a bottle legitimately
/// misses several of them.
private struct BrewFormulaDetail: Decodable {
    let name: String
    let desc: String?
    let homepage: String?
    let license: BrewLicense?
    let tap: String?
    let pinned: Bool?
    let outdated: Bool?
    let versions: Versions?
    let dependencies: [String]?
    let installed: [Installed]?

    struct Versions: Decodable {
        let stable: String?
    }

    struct Installed: Decodable {
        let version: String
        /// Unix timestamp of the install.
        let time: TimeInterval?
        let installed_on_request: Bool?
        let poured_from_bottle: Bool?
    }

    /// Bridges into the shared shape. `installedVersion` is nil for a
    /// formula that is not installed — a search hit, for instance — which
    /// the inspector's merge never asks about: it looks details up by name
    /// from the installed list, so an uninstalled entry cannot resurrect
    /// one.
    var detail: BrewDetail {
        // Several versions can sit side by side before a cleanup; the newest
        // is what a row shows.
        let installed = installed?.sorted(by: {
            $0.version.compare($1.version, options: .numeric) == .orderedDescending
        }).first
        return BrewDetail(
            name: name,
            displayName: nil,
            installedVersion: installed?.version,
            latestVersion: versions?.stable,
            isOutdated: outdated ?? false,
            description: desc,
            homepage: homepage,
            license: license?.text,
            tap: tap,
            dependencies: dependencies ?? [],
            installedAt: installed?.time.map { Date(timeIntervalSince1970: $0) },
            installedOnRequest: installed?.installed_on_request,
            pouredFromBottle: installed?.poured_from_bottle,
            pinned: pinned ?? false
        )
    }
}

/// One cask's details. Unlike formulae, `installed` is a bare version string
/// and `name` is an array whose first entry is the display name.
private struct BrewCaskDetail: Decodable {
    let token: String?
    let name: [String]?
    let desc: String?
    let homepage: String?
    let license: BrewLicense?
    let tap: String?
    let outdated: Bool?
    let version: String?
    let installed: String?

    /// Bridges into the shared shape. The token is the name every brew
    /// subcommand takes, so an entry without one cannot be acted on and is
    /// dropped; `installedVersion` is nil for a cask that is not installed —
    /// a search hit, which the inspector's merge never asks about.
    var detail: BrewDetail? {
        guard let token else { return nil }
        return BrewDetail(
            name: token,
            displayName: name?.first,
            installedVersion: installed,
            latestVersion: version,
            isOutdated: outdated ?? false,
            description: desc,
            homepage: homepage,
            license: license?.text,
            tap: tap,
            dependencies: [],
            installedAt: nil,
            installedOnRequest: nil,
            pouredFromBottle: nil,
            pinned: false
        )
    }
}

/// brew's license field is a string for single licenses and an array for
/// multi-license packages; both decode into one display text.
private struct BrewLicense: Decodable {
    let text: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            text = single
        } else if let many = try? container.decode([String].self) {
            text = many.joined(separator: ", ")
        } else {
            text = nil
        }
    }
}
