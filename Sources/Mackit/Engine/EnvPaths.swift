import Foundation

/// Resolves the toolchain locations a rule path can reference as `${VAR}`.
///
/// Rules were written against each tool's default cache location, which
/// meant a user who relocated a toolchain — a customized `GOPATH`,
/// `GRADLE_USER_HOME`, `PIP_CACHE_DIR`… — left the matching rules blind.
/// Resolution reads the variable from the process environment first and
/// falls back to the tool's documented default, so one path spelling covers
/// both.
///
/// A GUI-launched process only sees the environment launchd handed it:
/// variables exported solely in an interactive shell's rc file are invisible
/// here, while `launchctl setenv` and LaunchAgent environments are. The
/// defaults keep every rule working in the common case regardless.
enum EnvPaths {
    /// The tool's documented default for each supported variable, used when
    /// the variable is absent or empty. A value may itself reference another
    /// `${VAR}` — GOMODCACHE defaults to GOPATH's `pkg/mod`, and uv and
    /// pre-commit follow `XDG_CACHE_HOME` — which a second pass resolves.
    /// The table is acyclic by construction, and a self-referential value
    /// stabilizes under the no-change guard in `resolve`.
    ///
    /// The `~` belongs in the default, not in the rule path: a set variable
    /// holds an absolute path, and `~/` spliced in front of one yields a
    /// `/Users/x//absolute` spelling that exists nowhere.
    private static let defaults: [String: String] = [
        // Go, all three from `go env`'s documented defaults. GOCACHE's
        // default is os.UserCacheDir()/go-build, which on macOS ignores
        // XDG_CACHE_HOME. GOPATH may list several entries with the module
        // cache in the first — a list spliced in whole produces a path
        // that cannot exist, so such setups are missed.
        "GOPATH": "~/go",
        "GOMODCACHE": "${GOPATH}/pkg/mod",
        "GOCACHE": "~/Library/Caches/go-build",
        // XDG base directory: the fallback uv and pre-commit chain through.
        "XDG_CACHE_HOME": "~/.cache",
        "GRADLE_USER_HOME": "~/.gradle",
        "CARGO_HOME": "~/.cargo",
        "PUB_CACHE": "~/.pub-cache",
        "ANDROID_USER_HOME": "~/.android",
        // npm and pnpm both expose settings as `npm_config_*` variables.
        // pnpm's store default has PNPM_HOME and XDG_DATA_HOME variants
        // that are not followed.
        "npm_config_cache": "~/.npm",
        "npm_config_store_dir": "~/Library/pnpm/store",
        "npm_config_cache_dir": "~/Library/Caches/pnpm",
        "YARN_CACHE_FOLDER": "~/Library/Caches/Yarn",
        "DENO_DIR": "~/Library/Caches/deno",
        "PIP_CACHE_DIR": "~/Library/Caches/pip",
        "UV_CACHE_DIR": "${XDG_CACHE_HOME}/uv",
        "PRE_COMMIT_HOME": "${XDG_CACHE_HOME}/pre-commit",
        "POETRY_CACHE_DIR": "~/Library/Caches/pypoetry",
        // Bun documents ~/.bun/install/cache for the install cache, while on
        // macOS its runtime caches sit in the platform cache directory the
        // rule has always scanned. Keeping that directory as the default
        // preserves the existing scan and still follows an override.
        "BUN_INSTALL_CACHE_DIR": "~/Library/Caches/bun",
        // Ruby: GEM_HOME names where user-installed gems live (default
        // ~/.gem/ruby, one subdirectory per Ruby ABI version). RubyGems'
        // own spec cache is ~/.gem/specs when that directory already
        // exists and is not derived from GEM_HOME, so it is spelled out
        // literally in the rule. Bundler's global home defaults to
        // ~/.bundle, with its cache one level below (BUNDLE_USER_CACHE
        // in bundler's own settings table).
        "GEM_HOME": "~/.gem/ruby",
        "BUNDLE_USER_HOME": "~/.bundle",
        "BUNDLE_USER_CACHE": "${BUNDLE_USER_HOME}/cache",
        // Composer on macOS caches in ~/Library/Caches/composer; the
        // COMPOSER_CACHE_DIR override is honored (verified against
        // `composer config --global cache-dir`).
        "COMPOSER_CACHE_DIR": "~/Library/Caches/composer",
        // NuGet's documented Mac/Linux defaults (NUGET_PACKAGES and
        // NUGET_HTTP_CACHE_PATH override them).
        "NUGET_PACKAGES": "~/.nuget/packages",
        "NUGET_HTTP_CACHE_PATH": "~/.local/share/NuGet/v3-cache",
        // Coursier's platform defaults: ~/Library/Caches/Coursier/v1 on
        // macOS, ~/.cache/coursier/v1 on Linux (COURSIER_CACHE overrides).
        "COURSIER_CACHE": "~/Library/Caches/Coursier/v1",
        // Cabal's XDG layout: the package cache under XDG_CACHE_HOME and
        // the build store under XDG_STATE_HOME (CABAL_DIR relocates both).
        "XDG_STATE_HOME": "~/.local/state",
        // Elixir: hex's home defaults to ~/.hex (HEX_HOME overrides) and
        // Mix's home to ~/.mix (MIX_HOME overrides).
        "HEX_HOME": "~/.hex",
        "MIX_HOME": "~/.mix",
        // Zig's global cache: ZIG_GLOBAL_CACHE_DIR, else
        // $XDG_CACHE_HOME/zig, else ~/.cache/zig (zig's introspect
        // module). The default chains through XDG so an override of the
        // shared variable still relocates the rule.
        "ZIG_GLOBAL_CACHE_DIR": "${XDG_CACHE_HOME}/zig",
        // Crystal's cache: CRYSTAL_CACHE_DIR, else $XDG_CACHE_HOME/crystal,
        // else ~/.cache/crystal (crystal's codegen/cache_dir.cr).
        "CRYSTAL_CACHE_DIR": "${XDG_CACHE_HOME}/crystal",
        // Nimble's package directory: NIMBLE_DIR, else ~/.nimble.
        "NIMBLE_DIR": "~/.nimble",
    ]

    /// Substitute `${VAR}` references and expand `~`. A variable resolves
    /// from `environment` first, then from `defaults`. Environment values
    /// are locations, not expressions: they are spliced in as written, and
    /// only a token in them that names a known variable is expanded by the
    /// next pass (`GOPATH=${HOME}/gp`). Unknown tokens survive, leaving a
    /// path that cannot exist — the scan skips it.
    ///
    /// Substitution runs until the string stabilizes: chains are one level
    /// deep, and a value that resolves to itself stops the loop.
    static func resolve(
        _ path: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var resolved = path
        if resolved.contains("${") {
            for _ in 0..<4 {
                let substituted = substitute(resolved, environment: environment)
                if substituted == resolved { break }
                resolved = substituted
            }
        }
        return (resolved as NSString).expandingTildeInPath
    }

    /// One substitution pass over `${NAME}` tokens.
    private static func substitute(_ path: String, environment: [String: String]) -> String {
        var result = ""
        var rest = path[...]
        while let open = rest.range(of: "${") {
            result += rest[..<open.lowerBound]
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "}") else {
                result += "${"
                break
            }
            let name = String(rest[..<close.lowerBound])
            rest = rest[close.upperBound...]
            if let value = value(for: name, in: environment) {
                result += value
            } else {
                result += "${\(name)}"
            }
        }
        result += rest
        return result
    }

    private static func value(for name: String, in environment: [String: String]) -> String? {
        if let value = environment[name], !value.isEmpty {
            return value
        }
        return defaults[name]
    }
}
