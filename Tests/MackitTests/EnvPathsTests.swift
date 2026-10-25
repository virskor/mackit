import Foundation
import Testing

@testable import Mackit

struct EnvPathsTests {
    /// The environment is silent, so every variable falls back to the tool's
    /// documented default — the exact locations the rules were written
    /// against, which is what keeps the default launch behavior unchanged.
    @Test func defaultsApplyWhenEnvironmentIsSilent() {
        let home = NSHomeDirectory()
        #expect(EnvPaths.resolve("${GRADLE_USER_HOME}/caches", environment: [:]) == "\(home)/.gradle/caches")
        #expect(EnvPaths.resolve("${GOCACHE}", environment: [:]) == "\(home)/Library/Caches/go-build")
        #expect(EnvPaths.resolve("${npm_config_cache}/_cacache", environment: [:]) == "\(home)/.npm/_cacache")
        #expect(EnvPaths.resolve("${BUN_INSTALL_CACHE_DIR}", environment: [:]) == "\(home)/Library/Caches/bun")
    }

    /// A set variable wins over the default — the relocation the resolution
    /// exists for. Substituted values are absolute, so no stray `~/` prefix
    /// is spliced in front of them.
    @Test func environmentOverridesDefaults() {
        let environment = [
            "GRADLE_USER_HOME": "/opt/gradle-home",
            "UV_CACHE_DIR": "/data/uv",
        ]
        #expect(EnvPaths.resolve("${GRADLE_USER_HOME}/caches", environment: environment) == "/opt/gradle-home/caches")
        #expect(EnvPaths.resolve("${UV_CACHE_DIR}", environment: environment) == "/data/uv")
    }

    /// An empty value cannot name a location; it must fall back to the
    /// default rather than produce a path with a missing component.
    @Test func emptyEnvironmentValueFallsBackToDefault() {
        let home = NSHomeDirectory()
        #expect(EnvPaths.resolve("${PUB_CACHE}/hosted", environment: ["PUB_CACHE": ""]) == "\(home)/.pub-cache/hosted")
    }

    /// Defaults may chain through other variables: GOMODCACHE through
    /// GOPATH, and uv's XDG fallback — each resolved from the environment
    /// first, then from the default table.
    @Test func defaultsChainThroughOtherVariables() {
        let home = NSHomeDirectory()
        #expect(EnvPaths.resolve("${GOMODCACHE}/cache/download", environment: [:]) == "\(home)/go/pkg/mod/cache/download")
        #expect(EnvPaths.resolve("${GOMODCACHE}/cache/download", environment: ["GOPATH": "/srv/go"]) == "/srv/go/pkg/mod/cache/download")
        #expect(EnvPaths.resolve("${UV_CACHE_DIR}", environment: ["XDG_CACHE_HOME": "/xdg"]) == "/xdg/uv")
        #expect(EnvPaths.resolve("${PRE_COMMIT_HOME}", environment: [:]) == "\(home)/.cache/pre-commit")
    }

    /// A bare `$` without a brace is not a token and survives untouched.
    @Test func dollarWithoutBraceStaysLiteral() {
        #expect(EnvPaths.resolve("${PUB_CACHE}", environment: ["PUB_CACHE": "/opt/weird$dir/pub"]) == "/opt/weird$dir/pub")
    }

    /// An unknown token inside an environment value survives — the resulting
    /// path cannot exist, which the scan treats as "nothing to clean".
    @Test func unknownTokenInsideEnvironmentValueSurvives() {
        #expect(EnvPaths.resolve("${PUB_CACHE}", environment: ["PUB_CACHE": "/opt/${UNKNOWN}/pub"]) == "/opt/${UNKNOWN}/pub")
    }

    /// A known token inside an environment value is expanded by the next
    /// pass, so shell-style indirection still lands where the tool would.
    @Test func knownTokenInsideEnvironmentValueResolves() {
        let resolved = EnvPaths.resolve("${GOPATH}/bin", environment: ["GOPATH": "${HOME}/gp", "HOME": "/Users/test"])
        #expect(resolved == "/Users/test/gp/bin")
    }

    @Test func unknownVariablesStayUnresolved() {
        let path = "${NOT_A_TOOL_VARIABLE}/cache"
        #expect(EnvPaths.resolve(path, environment: [:]) == path)
    }

    /// The bulk of the catalog references no variables and must come out
    /// byte-identical to the plain tilde expansion.
    @Test func plainPathsPassThroughUnchanged() {
        let home = NSHomeDirectory()
        #expect(EnvPaths.resolve("~", environment: [:]) == home)
        #expect(EnvPaths.resolve("~/Library/Caches", environment: [:]) == "\(home)/Library/Caches")
        #expect(EnvPaths.resolve("/absolute/path", environment: [:]) == "/absolute/path")
    }

    /// A value that resolves to itself must terminate rather than loop —
    /// the no-change guard ends substitution and the literal (nonexistent)
    /// path is the result.
    @Test func selfReferentialEnvironmentValueTerminates() {
        #expect(EnvPaths.resolve("${GOPATH}/bin", environment: ["GOPATH": "${GOPATH}"]) == "${GOPATH}/bin")
    }

    /// A malformed token is left as written instead of swallowing the rest
    /// of the path.
    @Test func unterminatedTokenStaysLiteral() {
        #expect(EnvPaths.resolve("${DENO_DIR/cache", environment: [:]) == "${DENO_DIR/cache")
    }
}
