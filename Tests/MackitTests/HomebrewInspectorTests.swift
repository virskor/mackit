import Foundation
import Testing

@testable import Mackit

/// The inspector's parsers and its end-to-end merge.
///
/// The JSON fixtures are trimmed from real `brew info --json=v2` output
/// (brew 7.x) — field names, nesting and types are what brew actually
/// prints, so a parsing change that only works against invented shapes
/// fails here. The end-to-end test runs `inspect` with a canned `run`
/// closure and a fake brew path, so it never depends on the machine having
/// Homebrew; the only real filesystem access is the size measurement, which
/// reads fixture directories the canned output points at.
struct HomebrewInspectorTests {
    // MARK: - Version

    @Test func parsesVersionFromFirstLine() {
        // brew --version prints a second line with the core tap's git
        // revision; only the first line is the version.
        let output = "Homebrew 4.4.15\nHomebrew/homebrew-core (git revision abc123; last commit 2024-01-01)"
        #expect(HomebrewInspector.parseVersion(output) == "4.4.15")
    }

    @Test func versionWithoutTheHomebrewPrefixPassesThrough() {
        #expect(HomebrewInspector.parseVersion("4.4.15") == "4.4.15")
    }

    @Test func emptyOrPrefixOnlyVersionIsNil() {
        #expect(HomebrewInspector.parseVersion("") == nil)
        #expect(HomebrewInspector.parseVersion("Homebrew ") == nil)
        #expect(HomebrewInspector.parseVersion("Homebrew") == nil)
    }

    // MARK: - Installed list

    @Test func parsesInstalledList() {
        // Several installed versions sit side by side; the first is the
        // newest, which is what a row shows.
        let packages = HomebrewInspector.parseList(
            "wget 1.21.4\nnode 20.11.0 18.19.0\nhomebrew/cask/firefox 128.0",
            kind: .formula
        )
        #expect(packages.count == 3)
        #expect(packages[0].name == "wget")
        #expect(packages[0].installedVersion == "1.21.4")
        #expect(packages[0].kind == .formula)
        #expect(packages[1].name == "node")
        #expect(packages[1].installedVersion == "20.11.0")
        #expect(packages[2].name == "homebrew/cask/firefox")
    }

    @Test func listSkipsLinesWithoutAVersion() {
        let packages = HomebrewInspector.parseList("wget\n\nnode 20.11.0", kind: .formula)
        #expect(packages.count == 1)
        #expect(packages[0].name == "node")
    }

    // MARK: - JSON details

    /// A formula payload, trimmed from real `brew info --json=v2 brotli`.
    private static let formulaJSON = """
    {"formulae":[{"name":"brotli","desc":"Generic-purpose lossless compression algorithm by Google","homepage":"https://github.com/google/brotli","license":"MIT","tap":"homebrew/core","pinned":false,"outdated":true,"versions":{"stable":"1.2.1","head":"HEAD","bottle":true},"dependencies":[],"installed":[{"sbom":"/opt/homebrew/Cellar/brotli/1.2.0/sbom.spdx.json","version":"1.2.0","used_options":[],"built_as_bottle":true,"poured_from_bottle":true,"time":1791862896,"runtime_dependencies":[],"installed_on_request":false}]}]}
    """

    /// A cask payload, trimmed from real `brew info --cask --json=v2 codex`.
    /// Note: no `license` key — optional fields must stay optional.
    private static let caskJSON = """
    {"casks":[{"token":"codex","name":["Codex"],"desc":"OpenAI's coding agent that runs in your terminal","homepage":"https://github.com/openai/codex","tap":"homebrew/cask","outdated":true,"version":"0.164.0","installed":"0.163.0","auto_updates":null}]}
    """

    @Test func parsesFormulaDetails() throws {
        let details = HomebrewInspector.parseInfoJSON(Self.formulaJSON, kind: .formula)
        let detail = try #require(details.first)
        #expect(detail.name == "brotli")
        #expect(detail.installedVersion == "1.2.0")
        #expect(detail.latestVersion == "1.2.1")
        #expect(detail.isOutdated)
        #expect(detail.description == "Generic-purpose lossless compression algorithm by Google")
        #expect(detail.homepage == "https://github.com/google/brotli")
        #expect(detail.license == "MIT")
        #expect(detail.tap == "homebrew/core")
        #expect(detail.installedOnRequest == false)
        #expect(detail.pouredFromBottle == true)
        #expect(detail.pinned == false)
        // brew reports the install time as unix seconds.
        #expect(detail.installedAt == Date(timeIntervalSince1970: 1791862896))
        #expect(detail.displayName == nil, "formulae have no separate display name")
    }

    @Test func parsesCaskDetails() throws {
        let details = HomebrewInspector.parseInfoJSON(Self.caskJSON, kind: .cask)
        let detail = try #require(details.first)
        #expect(detail.name == "codex")
        #expect(detail.displayName == "Codex")
        #expect(detail.installedVersion == "0.163.0")
        #expect(detail.latestVersion == "0.164.0")
        #expect(detail.isOutdated)
        #expect(detail.license == nil, "a missing license decodes as nil, not a crash")
        #expect(detail.dependencies.isEmpty, "casks report no dependencies in this shape")
        #expect(detail.installedAt == nil)
    }

    @Test func undecodableJSONYieldsNoDetails() {
        // brew prints the error to stderr and exits nonzero; whatever lands
        // on stdout must not crash the decode.
        #expect(HomebrewInspector.parseInfoJSON("Error: No available formula", kind: .formula).isEmpty)
        #expect(HomebrewInspector.parseInfoJSON("", kind: .cask).isEmpty)
    }

    @Test func formulaWithoutAnInstalledEntryIsDropped() {
        // A stale index can name a formula that was since removed; it must
        // not resurrect as an installed package.
        let json = """
        {"formulae":[{"name":"ghost","versions":{"stable":"1.0"},"installed":[]}]}
        """
        #expect(HomebrewInspector.parseInfoJSON(json, kind: .formula).isEmpty)
    }

    @Test func newestOfSeveralInstalledVersionsWins() {
        // Two versions side by side (pre-cleanup); the newest is the row's.
        let json = """
        {"formulae":[{"name":"node","versions":{"stable":"21.0.0"},"installed":[{"version":"18.19.0","time":1},{"version":"20.11.0","time":2}]}]}
        """
        let details = HomebrewInspector.parseInfoJSON(json, kind: .formula)
        #expect(details.count == 1)
        #expect(details[0].installedVersion == "20.11.0")
    }

    // MARK: - End-to-end merge

    @Test func inspectMergesCannedOutputIntoASnapshot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-brew-\(UUID().uuidString)", isDirectory: true)
        let cellar = base.appendingPathComponent("Cellar", isDirectory: true)
        let cache = base.appendingPathComponent("Caches", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cellar.appendingPathComponent("brotli/1.2.0", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: 8192).write(to: cellar.appendingPathComponent("brotli/1.2.0/file.bin"))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: cache.appendingPathComponent("download.tgz"))
        defer { try? FileManager.default.removeItem(at: base) }

        let run: BrewCommand = { arguments, _ in
            switch arguments {
            case ["--version"]: "Homebrew 4.4.15"
            case ["--prefix"]: "/opt/homebrew"
            case ["--cache"]: cache.path
            case ["--cellar"]: cellar.path
            case ["list", "--versions"]: "brotli 1.2.0\nnode 20.11.0"
            case ["list", "--cask", "--versions"]: "codex 0.163.0"
            case ["info", "--json=v2", "brotli", "node"]: Self.formulaJSON
            case ["info", "--cask", "--json=v2", "codex"]: Self.caskJSON
            default: nil
            }
        }

        let snapshot = try #require(await HomebrewInspector.inspect(brewPath: "/fake/brew", run: run))

        #expect(snapshot.brewPath == "/fake/brew")
        #expect(snapshot.version == "4.4.15")
        #expect(snapshot.prefix == "/opt/homebrew")
        #expect(snapshot.detailsAvailable)

        #expect(snapshot.formulae.count == 2)
        #expect(snapshot.formulae[0].name == "brotli")
        // The formula with a fixture directory measures its real size; the
        // one without a directory measures as 0.
        #expect(snapshot.formulae[0].size ?? 0 > 0)
        #expect(snapshot.formulae[1].size == 0)
        // Details merged onto the listed package: outdated + latest.
        #expect(snapshot.formulae[0].isOutdated)
        #expect(snapshot.formulae[0].latestVersion == "1.2.1")
        #expect(snapshot.formulae[0].license == "MIT")

        #expect(snapshot.casks.count == 1)
        #expect(snapshot.casks[0].displayName == "Codex")
        #expect(snapshot.casks[0].size == nil, "casks carry no size")

        #expect(snapshot.outdated.count == 2)
        #expect(snapshot.cacheSize > 0)
        #expect(snapshot.cellarSize > 0)
        #expect(snapshot.isUsable)
    }

    @Test func inspectDegradesWhenDetailsFail() async throws {
        // An old brew without json=v2: names and versions still land, and
        // the page is told details are unavailable.
        let run: BrewCommand = { arguments, _ in
            switch arguments {
            case ["--version"]: "Homebrew 2.7.0"
            case ["--prefix"]: "/usr/local"
            case ["--cache"]: "/nonexistent-cache"
            case ["--cellar"]: "/nonexistent-cellar"
            case ["list", "--versions"]: "wget 1.21.4"
            case ["list", "--cask", "--versions"]: ""
            default: nil
            }
        }
        let snapshot = try #require(await HomebrewInspector.inspect(brewPath: "/fake/brew", run: run))
        #expect(!snapshot.detailsAvailable)
        #expect(snapshot.formulae.count == 1)
        #expect(snapshot.formulae[0].name == "wget")
        #expect(snapshot.formulae[0].installedVersion == "1.21.4")
        #expect(snapshot.formulae[0].description == nil)
        #expect(snapshot.formulae[0].size == 0)
    }

    @Test func inspectFallsBackWhenPathQueriesFail() async throws {
        // A broken brew that answers nothing must still produce a snapshot
        // with the Apple Silicon prefix default, not nil.
        let run: BrewCommand = { _, _ in nil }
        let snapshot = try #require(await HomebrewInspector.inspect(brewPath: "/fake/brew", run: run))
        #expect(snapshot.version == nil)
        #expect(snapshot.prefix == "/opt/homebrew")
        #expect(snapshot.formulae.isEmpty)
        #expect(snapshot.casks.isEmpty)
        #expect(!snapshot.isUsable)
    }
}
