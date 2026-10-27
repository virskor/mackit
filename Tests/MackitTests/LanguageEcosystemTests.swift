import Foundation
import Testing

@testable import Mackit

/// Coverage for the language ecosystems added beyond the original catalog
/// (Ruby, PHP, .NET, Scala, Haskell, Clojure, Elixir, Lua, Julia, OCaml,
/// Zig, Nim, Crystal, Perl).
///
/// Every path these rules target was verified against the tool itself
/// where it is installed, and against the tool's own source or official
/// documentation where it is not — see the comments in RulesCatalog and
/// EnvPaths. What is asserted here is the contract those rules depend on:
/// the ids exist, the variables resolve to the documented defaults (and
/// follow their overrides), and the risk levels match what deleting each
/// location actually costs.
struct LanguageEcosystemTests {
    /// The rule ids the new ecosystems add. Kept as a literal list so a
    /// rename or removal in the catalog fails here by name.
    private static let newScanRuleIDs = [
        "ruby.gem-specs", "ruby.gem-user", "ruby.bundle-cache",
        "php.composer-cache",
        "dotnet.nuget-packages", "dotnet.nuget-http-cache",
        "scala.coursier-cache", "scala.sbt-boot", "scala.ivy2-cache",
        "haskell.cabal-cache", "haskell.cabal-store",
        "haskell.stack-programs", "haskell.stack-snapshots",
        "clojure.gitlibs", "clojure.lein",
        "elixir.hex-cache", "elixir.mix-archives", "elixir.rebar3-cache",
        "lua.luarocks",
        "julia.compiled", "julia.registries", "julia.packages",
        "ocaml.opam-download-cache", "ocaml.opam-repo",
        "zig.cache",
        "nim.cache", "nim.nimble",
        "crystal.cache",
        "perl.cpan-sources", "perl.cpan-build",
    ]

    private static let newCLIRuleIDs = [
        "cli.gem-cleanup",
        "cli.composer-clear-cache",
        "cli.dotnet-nuget-http-cache",
        "cli.dotnet-nuget-global-packages",
        "cli.crystal-clear-cache",
    ]

    private static let newCategories: [JunkCategory] = [
        .ruby, .php, .dotnet, .scala, .haskell, .clojure, .elixir,
        .lua, .julia, .ocaml, .zig, .nim, .crystal, .perl,
    ]

    @Test func everyNewRuleIsInTheCatalog() {
        let scanIDs = Set(RulesCatalog.scanRules.map(\.id))
        for id in Self.newScanRuleIDs {
            #expect(scanIDs.contains(id), "\(id) missing from scanRules")
        }
        let cliIDs = Set(RulesCatalog.cliRules.map(\.id))
        for id in Self.newCLIRuleIDs {
            #expect(cliIDs.contains(id), "\(id) missing from cliRules")
        }
    }

    /// The generic localization and uniqueness tests in RulesCatalogTests /
    /// LocalizationTests iterate the catalog; this pins that the new rules
    /// are reachable through those loops rather than dead entries.
    @Test func everyNewCategoryCarriesRulesAndDeveloperScope() {
        let staticCategories = Set(RulesCatalog.scanRules.map(\.category))
            .union(RulesCatalog.cliRules.map(\.category))
        for category in Self.newCategories {
            #expect(staticCategories.contains(category), "\(category.rawValue) has no rules")
            #expect(category.scope == .developer, "\(category.rawValue) is not developer-scoped")
        }
    }

    /// The documented default of each new variable, with a silent
    /// environment — the locations the rules were written against.
    @Test func newEnvDefaultsResolveToDocumentedLocations() {
        let home = NSHomeDirectory()
        #expect(EnvPaths.resolve("${GEM_HOME}", environment: [:]) == "\(home)/.gem/ruby")
        #expect(EnvPaths.resolve("${BUNDLE_USER_CACHE}", environment: [:]) == "\(home)/.bundle/cache")
        #expect(EnvPaths.resolve("${COMPOSER_CACHE_DIR}", environment: [:]) == "\(home)/Library/Caches/composer")
        #expect(EnvPaths.resolve("${NUGET_PACKAGES}", environment: [:]) == "\(home)/.nuget/packages")
        #expect(EnvPaths.resolve("${NUGET_HTTP_CACHE_PATH}", environment: [:]) == "\(home)/.local/share/NuGet/v3-cache")
        #expect(EnvPaths.resolve("${COURSIER_CACHE}", environment: [:]) == "\(home)/Library/Caches/Coursier/v1")
        #expect(EnvPaths.resolve("${HEX_HOME}", environment: [:]) == "\(home)/.hex")
        #expect(EnvPaths.resolve("${MIX_HOME}/archives", environment: [:]) == "\(home)/.mix/archives")
        #expect(EnvPaths.resolve("${ZIG_GLOBAL_CACHE_DIR}", environment: [:]) == "\(home)/.cache/zig")
        #expect(EnvPaths.resolve("${CRYSTAL_CACHE_DIR}", environment: [:]) == "\(home)/.cache/crystal")
        #expect(EnvPaths.resolve("${NIMBLE_DIR}", environment: [:]) == "\(home)/.nimble")
        // Cabal's XDG layout and Nim's per-project nimcache both hang off
        // the shared XDG variables, whose own defaults then apply.
        #expect(EnvPaths.resolve("${XDG_CACHE_HOME}/cabal", environment: [:]) == "\(home)/.cache/cabal")
        #expect(EnvPaths.resolve("${XDG_STATE_HOME}/cabal", environment: [:]) == "\(home)/.local/state/cabal")
        #expect(EnvPaths.resolve("${XDG_CACHE_HOME}/nim", environment: [:]) == "\(home)/.cache/nim")
    }

    /// A relocated toolchain must move its rules with it: the variable
    /// wins over the default, including through the bundler chain.
    @Test func newEnvVariablesFollowOverrides() {
        #expect(EnvPaths.resolve("${BUNDLE_USER_CACHE}", environment: ["BUNDLE_USER_HOME": "/srv/bundle"]) == "/srv/bundle/cache")
        #expect(EnvPaths.resolve("${BUNDLE_USER_CACHE}", environment: ["BUNDLE_USER_CACHE": "/srv/cache"]) == "/srv/cache")
        #expect(EnvPaths.resolve("${COMPOSER_CACHE_DIR}", environment: ["COMPOSER_CACHE_DIR": "/tmp/cc"]) == "/tmp/cc")
        #expect(EnvPaths.resolve("${HEX_HOME}/cache.*", environment: ["HEX_HOME": "/opt/hex"]) == "/opt/hex/cache.*")
        #expect(EnvPaths.resolve("${ZIG_GLOBAL_CACHE_DIR}", environment: ["XDG_CACHE_HOME": "/xdg"]) == "/xdg/zig")
    }

    /// Risk is what deleting the location costs: a cache re-fetches, a
    /// package store or toolchain re-downloads wholesale.
    @Test func riskLevelsMatchWhatDeletingCosts() {
        func risk(of id: String) -> RiskLevel? {
            RulesCatalog.scanRules.first { $0.id == id }?.risk
        }

        let safe = [
            "ruby.gem-specs", "ruby.bundle-cache", "php.composer-cache",
            "dotnet.nuget-http-cache", "scala.coursier-cache", "scala.ivy2-cache",
            "haskell.cabal-cache", "clojure.gitlibs", "elixir.hex-cache",
            "elixir.mix-archives", "elixir.rebar3-cache", "julia.compiled",
            "julia.registries", "ocaml.opam-download-cache", "ocaml.opam-repo",
            "zig.cache", "nim.cache", "crystal.cache", "perl.cpan-sources",
            "perl.cpan-build",
        ]
        let review = [
            "ruby.gem-user", "dotnet.nuget-packages", "scala.sbt-boot",
            "haskell.cabal-store", "haskell.stack-programs", "haskell.stack-snapshots",
            "clojure.lein", "lua.luarocks", "julia.packages", "nim.nimble",
        ]
        for id in safe {
            #expect(risk(of: id) == .safe, "\(id) should be safe")
        }
        for id in review {
            #expect(risk(of: id) == .review, "\(id) should be review")
        }
    }

    /// Hex keeps its API credentials in ~/.hex/hex.config, next to the
    /// cache files. A children sweep of ~/.hex would offer the config for
    /// deletion; the glob targets only the cache files.
    @Test func hexRuleSweepsCacheFilesOnly() throws {
        let rule = try #require(RulesCatalog.scanRules.first { $0.id == "elixir.hex-cache" })
        guard case .glob(let pattern) = rule.target else {
            Issue.record("elixir.hex-cache must be a glob, not a directory sweep")
            return
        }
        #expect(pattern == "${HEX_HOME}/cache.*")
    }

    /// The CLI rules invoke each tool's own documented cleanup command,
    /// verified against the tools' references.
    @Test func newCLIRulesInvokeOfficialCommands() {        let byID = Dictionary(uniqueKeysWithValues: RulesCatalog.cliRules.map { ($0.id, $0) })

        let gem = byID["cli.gem-cleanup"]
        #expect(gem?.executable == "gem")
        #expect(gem?.arguments == ["cleanup"])
        #expect(gem?.category == .ruby)

        let composer = byID["cli.composer-clear-cache"]
        #expect(composer?.executable == "composer")
        #expect(composer?.arguments == ["clear-cache"])
        #expect(composer?.category == .php)

        let httpCache = byID["cli.dotnet-nuget-http-cache"]
        #expect(httpCache?.executable == "dotnet")
        #expect(httpCache?.arguments == ["nuget", "locals", "http-cache", "--clear"])
        #expect(httpCache?.risk == .safe)

        let globalPackages = byID["cli.dotnet-nuget-global-packages"]
        #expect(globalPackages?.arguments == ["nuget", "locals", "global-packages", "--clear"])
        #expect(globalPackages?.risk == .review)

        let crystal = byID["cli.crystal-clear-cache"]
        #expect(crystal?.executable == "crystal")
        #expect(crystal?.arguments == ["clear_cache"])
        #expect(crystal?.category == .crystal)
    }

    /// Every new ecosystem carries a brand mark, and each mark must parse.
    /// A file that fails to load leaves the category drawing nothing at
    /// all (BrandLogo.elements falls back to an empty list), which would
    /// ship a blank icon silently — the load itself only logs.
    @Test func everyNewBrandMarkLoads() {
        for category in Self.newCategories {
            guard let logo = category.brandLogo else {
                Issue.record("\(category.rawValue) has no brand logo")
                continue
            }
            #expect(!logo.elements.isEmpty, "\(logo.rawValue) failed to parse")
        }
    }
}
