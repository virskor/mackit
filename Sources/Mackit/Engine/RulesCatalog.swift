import Foundation

/// The catalog of junk cleaning rules. Paths start with `~` and may reference
/// a toolchain location as `${VAR}`; both are expanded at runtime (`EnvPaths`).
enum RulesCatalog {
    static let scanRules: [ScanRule] = [
        // MARK: Xcode
        ScanRule(
            id: "xcode.deriveddata",
            category: .xcode,
            target: .children("~/Library/Developer/Xcode/DerivedData"),
            risk: .safe
        ),
        ScanRule(
            id: "xcode.archives",
            category: .xcode,
            target: .children("~/Library/Developer/Xcode/Archives"),
            risk: .review
        ),
        ScanRule(
            id: "xcode.devicesupport",
            category: .xcode,
            target: .children("~/Library/Developer/Xcode/iOS DeviceSupport"),
            risk: .review
        ),
        ScanRule(
            id: "xcode.watchdevicesupport",
            category: .xcode,
            target: .children("~/Library/Developer/Xcode/watchOS DeviceSupport"),
            risk: .review
        ),
        // DocumentationCache holds the downloaded DocC archives and
        // DocumentationIndex their search index; deleting either is the
        // documented fix for broken doc search, and Xcode re-downloads and
        // re-indexes both on demand. One glob covers the pair.
        ScanRule(
            id: "xcode.docs",
            category: .xcode,
            target: .glob("~/Library/Developer/Xcode/Documentation*"),
            risk: .safe
        ),
        ScanRule(
            id: "xcode.swiftpm",
            category: .xcode,
            target: .children("~/Library/Caches/org.swift.swiftpm"),
            risk: .safe
        ),
        ScanRule(
            id: "xcode.usercache",
            category: .xcode,
            target: .children("~/Library/Caches/com.apple.dt.Xcode"),
            risk: .safe
        ),
        ScanRule(
            id: "xcode.products",
            category: .xcode,
            target: .glob("~/Library/Developer/Xcode/Products/*"),
            risk: .safe
        ),

        // MARK: Simulator
        ScanRule(
            id: "sim.coresimulator-caches",
            category: .simulator,
            target: .children("~/Library/Developer/CoreSimulator/Caches"),
            risk: .safe
        ),
        ScanRule(
            id: "sim.device-caches",
            category: .simulator,
            target: .glob("~/Library/Developer/CoreSimulator/Devices/*/data/Library/Caches/*"),
            risk: .safe
        ),
        ScanRule(
            id: "sim.device-tmp",
            category: .simulator,
            target: .glob("~/Library/Developer/CoreSimulator/Devices/*/data/tmp/*"),
            risk: .safe
        ),
        // CoreSimulator's own logs are not listed here: they live under
        // ~/Library/Logs/CoreSimulator, which the user-logs rule already
        // covers as a child — listing both would count the same bytes twice.
        ScanRule(
            id: "sim.help",
            category: .simulator,
            target: .children("~/Library/Caches/com.apple.iphonesimulator"),
            risk: .safe
        ),

        // MARK: Android / Gradle
        ScanRule(
            id: "android.gradle-caches",
            category: .android,
            target: .children("${GRADLE_USER_HOME}/caches"),
            risk: .safe
        ),
        ScanRule(
            id: "android.gradle-wrapper",
            category: .android,
            target: .children("${GRADLE_USER_HOME}/wrapper/dists"),
            risk: .safe
        ),
        ScanRule(
            id: "android.gradle-daemon-logs",
            category: .android,
            target: .glob("${GRADLE_USER_HOME}/daemon/*/*.log"),
            risk: .safe
        ),
        ScanRule(
            id: "android.android-cache",
            category: .android,
            target: .children("${ANDROID_USER_HOME}/build-cache"),
            risk: .safe
        ),
        // sdkmanager's downloaded repository manifests; refreshed on the next query
        ScanRule(
            id: "android.sdk-cache",
            category: .android,
            target: .children("${ANDROID_USER_HOME}/cache"),
            risk: .safe
        ),
        // JDK distributions the Gradle toolchain downloads; big re-downloads, hence review
        ScanRule(
            id: "android.gradle-jdks",
            category: .android,
            target: .children("${GRADLE_USER_HOME}/jdks"),
            risk: .review
        ),
        ScanRule(
            id: "android.studio-caches",
            category: .android,
            target: .glob("~/Library/Caches/Google/AndroidStudio*/*"),
            risk: .safe
        ),
        // Review, not safe: ~/.konan also holds the Kotlin/Native compiler
        // distributions, which are hundreds of MB to re-download.
        ScanRule(
            id: "android.konan",
            category: .android,
            target: .children("~/.konan"),
            risk: .review
        ),
        ScanRule(
            id: "android.maven",
            category: .android,
            target: .directory("~/.m2/repository"),
            risk: .review
        ),

        // MARK: Go
        ScanRule(
            id: "go.build-cache",
            category: .go,
            target: .children("${GOCACHE}"),
            risk: .safe
        ),
        ScanRule(
            id: "go.mod-download",
            category: .go,
            target: .children("${GOMODCACHE}/cache/download"),
            risk: .safe
        ),
        // MARK: Node / Frontend
        ScanRule(
            id: "node.npm-cacache",
            category: .node,
            target: .children("${npm_config_cache}/_cacache"),
            risk: .safe
        ),
        ScanRule(
            id: "node.yarn-cache",
            category: .node,
            target: .children("${YARN_CACHE_FOLDER}"),
            risk: .safe
        ),
        ScanRule(
            id: "node.yarn-berry",
            category: .node,
            target: .children("~/.yarn/berry/cache"),
            risk: .safe
        ),
        // Review, not safe: pnpm's own maintenance command is `store prune`
        // (the CLI rule below), which drops only unreferenced packages.
        // Deleting the store wholesale makes every project re-download its
        // whole dependency set on the next install, which is exactly what the
        // review level means.
        ScanRule(
            id: "node.pnpm-store",
            category: .node,
            target: .directory("${npm_config_store_dir}"),
            risk: .review
        ),
        ScanRule(
            id: "node.pnpm-cache",
            category: .node,
            target: .children("${npm_config_cache_dir}"),
            risk: .safe
        ),
        ScanRule(
            id: "node.bun-cache",
            category: .node,
            target: .children("${BUN_INSTALL_CACHE_DIR}"),
            risk: .safe
        ),
        ScanRule(
            id: "node.node-gyp",
            category: .node,
            target: .children("~/Library/Caches/node-gyp"),
            risk: .safe
        ),
        ScanRule(
            id: "node.electron-gyp",
            category: .node,
            target: .children("~/.electron-gyp"),
            risk: .safe
        ),
        ScanRule(
            id: "node.typescript",
            category: .node,
            target: .children("~/Library/Caches/typescript"),
            risk: .safe
        ),
        // DENO_DIR is honored with its documented macOS default (the Linux
        // `~/.cache/deno` spelling never exists here).
        ScanRule(
            id: "node.deno",
            category: .node,
            target: .children("${DENO_DIR}"),
            risk: .safe
        ),
        // One environment per package ever run through npx; re-downloaded on demand
        ScanRule(
            id: "node.npx",
            category: .node,
            target: .children("${npm_config_cache}/_npx"),
            risk: .safe
        ),

        // MARK: Flutter / Dart
        ScanRule(
            id: "flutter.pub-hosted",
            category: .flutter,
            target: .children("${PUB_CACHE}/hosted"),
            risk: .safe
        ),
        ScanRule(
            id: "flutter.pub-git",
            category: .flutter,
            target: .children("${PUB_CACHE}/git"),
            risk: .safe
        ),
        ScanRule(
            id: "flutter.pub-temp",
            category: .flutter,
            target: .children("${PUB_CACHE}/.temp"),
            risk: .safe
        ),
        ScanRule(
            id: "flutter.dart-tool",
            category: .flutter,
            target: .directory("~/.dartServer"),
            risk: .safe
        ),
        ScanRule(
            id: "flutter.pub-cache-bin",
            category: .flutter,
            target: .children("${PUB_CACHE}/bin"),
            risk: .review
        ),

        // MARK: Rust
        ScanRule(
            id: "rust.registry-cache",
            category: .rust,
            target: .children("${CARGO_HOME}/registry/cache"),
            risk: .safe
        ),
        ScanRule(
            id: "rust.registry-src",
            category: .rust,
            target: .children("${CARGO_HOME}/registry/src"),
            risk: .safe
        ),
        ScanRule(
            id: "rust.git-db",
            category: .rust,
            target: .children("${CARGO_HOME}/git/db"),
            risk: .safe
        ),

        // MARK: Python
        ScanRule(
            id: "python.pip-cache",
            category: .python,
            target: .children("${PIP_CACHE_DIR}"),
            risk: .safe
        ),
        ScanRule(
            id: "python.uv-cache",
            category: .python,
            target: .children("${UV_CACHE_DIR}"),
            risk: .safe
        ),
        ScanRule(
            id: "python.poetry-cache",
            category: .python,
            target: .children("${POETRY_CACHE_DIR}"),
            risk: .safe
        ),
        ScanRule(
            id: "python.precommit",
            category: .python,
            target: .children("${PRE_COMMIT_HOME}"),
            risk: .safe
        ),

        // MARK: Ruby
        // RubyGems' spec cache: `gem env` reports it as ~/.gem/specs
        // (RubyGems' defaults.rb derives it from the user home, falling
        // back to the XDG cache dir only when ~/.gem/specs is absent).
        // It is the compact-index client cache, re-fetched on demand.
        ScanRule(
            id: "ruby.gem-specs",
            category: .ruby,
            target: .directory("~/.gem/specs"),
            risk: .safe
        ),
        // GEM_HOME's default location: user-installed gems, one subtree
        // per Ruby ABI version. Review, not safe — every user-installed
        // gem re-downloads.
        ScanRule(
            id: "ruby.gem-user",
            category: .ruby,
            target: .children("${GEM_HOME}"),
            risk: .review
        ),
        // Bundler's global cache: bundler's settings table maps
        // BUNDLE_USER_CACHE to $BUNDLE_USER_HOME/cache, and
        // BUNDLE_USER_HOME to ~/.bundle. Holds the compact index cache
        // and anything `bundle cache` stashed; rebuilt on the next run.
        ScanRule(
            id: "ruby.bundle-cache",
            category: .ruby,
            target: .children("${BUNDLE_USER_CACHE}"),
            risk: .safe
        ),

        // MARK: PHP / Composer
        // Composer's cache dir on macOS, verified against
        // `composer config --global cache-dir` (files/repo/vcs
        // children); COMPOSER_CACHE_DIR overrides.
        ScanRule(
            id: "php.composer-cache",
            category: .php,
            target: .children("${COMPOSER_CACHE_DIR}"),
            risk: .safe
        ),

        // MARK: .NET / NuGet
        // NuGet's documented Mac/Linux defaults (Microsoft's "Managing
        // the global packages and cache folders"). The global-packages
        // folder holds every extracted package — clearing it forces a
        // full restore of every project, hence review.
        ScanRule(
            id: "dotnet.nuget-packages",
            category: .dotnet,
            target: .children("${NUGET_PACKAGES}"),
            risk: .review
        ),
        // The HTTP response cache: feed metadata and .nupkg downloads,
        // expired on their own after roughly 30 minutes.
        ScanRule(
            id: "dotnet.nuget-http-cache",
            category: .dotnet,
            target: .children("${NUGET_HTTP_CACHE_PATH}"),
            risk: .safe
        ),

        // MARK: Scala / JVM
        // Coursier's platform defaults (get-coursier.io):
        // ~/Library/Caches/Coursier/v1 on macOS, ~/.cache/coursier/v1 on
        // Linux; COURSIER_CACHE overrides. It is sbt's and the Scala
        // CLI's download cache — artifacts re-download.
        ScanRule(
            id: "scala.coursier-cache",
            category: .scala,
            target: .children("${COURSIER_CACHE}"),
            risk: .safe
        ),
        // sbt's boot directory (the sbt FAQ names ~/.sbt/boot) holds
        // sbt's own launcher jars and the Scala compiler it runs —
        // hundreds of MB to re-fetch, hence review.
        ScanRule(
            id: "scala.sbt-boot",
            category: .scala,
            target: .children("~/.sbt/boot"),
            risk: .review
        ),
        // Ivy's default cache (Apache Ivy's docs: ~/.ivy2/cache), still
        // used by older sbt builds and Ant+Ivy setups.
        ScanRule(
            id: "scala.ivy2-cache",
            category: .scala,
            target: .children("~/.ivy2/cache"),
            risk: .safe
        ),

        // MARK: Haskell
        // Cabal's XDG layout (cabal's configuration docs): the package
        // cache defaults to ~/.cache/cabal on Unix — macOS included —
        // and the build store to ~/.local/state/cabal. The rules cover
        // that default layout only: a CABAL_DIR relocation is not
        // followed. The cache is downloaded tarballs and the index;
        // the store is what every project links against, so clearing
        // it rebuilds every dependency, hence review.
        ScanRule(
            id: "haskell.cabal-cache",
            category: .haskell,
            target: .children("${XDG_CACHE_HOME}/cabal"),
            risk: .safe
        ),
        ScanRule(
            id: "haskell.cabal-store",
            category: .haskell,
            target: .children("${XDG_STATE_HOME}/cabal"),
            risk: .review
        ),
        // Stack's root (docs.haskellstack.org: ~/.stack by default).
        // The rules target that default root; a STACK_ROOT relocation
        // is not followed. programs holds the GHC toolchains stack
        // downloaded and snapshots the per-snapshot dependency builds —
        // both are big re-downloads, so each is its own review-level
        // entry rather than a sweep of the whole root, which also holds
        // the user's config.yaml.
        ScanRule(
            id: "haskell.stack-programs",
            category: .haskell,
            target: .children("~/.stack/programs"),
            risk: .review
        ),
        ScanRule(
            id: "haskell.stack-snapshots",
            category: .haskell,
            target: .children("~/.stack/snapshots"),
            risk: .review
        ),

        // MARK: Clojure
        // tools.deps' git dependency cache (Clojure's deps.edn
        // reference: "Git libs are downloaded by default to the
        // ~/.gitlibs directory") — re-cloned on the next resolve.
        ScanRule(
            id: "clojure.gitlibs",
            category: .clojure,
            target: .children("~/.gitlibs"),
            risk: .safe
        ),
        // Leiningen's self-installed standalone jar (the lein script:
        // LEIN_HOME defaults to ~/.lein, the jar lives in
        // self-installs/). It re-downloads itself on the next run, but
        // it is the build tool itself — review.
        ScanRule(
            id: "clojure.lein",
            category: .clojure,
            target: .glob("~/.lein/self-installs/*"),
            risk: .review
        ),

        // MARK: Elixir / Erlang
        // Hex's registry cache: Hex.Registry.Server writes cache.ets and
        // cache.bin into the cache_home setting, which defaults to
        // ~/.hex (HEX_HOME overrides). The glob keeps hex.config — the
        // API credentials — out of the sweep.
        ScanRule(
            id: "elixir.hex-cache",
            category: .elixir,
            target: .glob("${HEX_HOME}/cache.*"),
            risk: .safe
        ),
        // Mix's archives (Mix's docs: MIX_HOME defaults to ~/.mix and
        // MIX_ARCHIVES to ~/.mix/archives) — the hex and rebar archives
        // `mix local.hex` / `mix local.rebar` install.
        ScanRule(
            id: "elixir.mix-archives",
            category: .elixir,
            target: .children("${MIX_HOME}/archives"),
            risk: .safe
        ),
        // Rebar3's global cache (rebar3's rebar_dir module: cache_dir
        // defaults to ~/.cache/rebar3) — the dependency downloads of
        // Erlang builds. The rule targets that default; an install
        // that overrides the global rebar directory is not followed.
        ScanRule(
            id: "elixir.rebar3-cache",
            category: .elixir,
            target: .children("~/.cache/rebar3"),
            risk: .safe
        ),

        // MARK: Lua
        // LuaRocks' user tree (luarocks' config module: home_tree
        // defaults to $HOME/.luarocks on Unix). The sweep takes the
        // whole tree: installed rocks, plus the bin/ executables and
        // share/ Lua modules the tool installs there — all of it
        // reinstalls, hence review.
        ScanRule(
            id: "lua.luarocks",
            category: .lua,
            target: .children("~/.luarocks"),
            risk: .review
        ),

        // MARK: Julia
        // Julia's precompile cache (julia's initdefs.jl: the default
        // depot is ~/.julia); the compiled images regenerate on
        // demand. The rules target the default depot — a
        // JULIA_DEPOT_PATH relocation (a colon-separated depot list)
        // is not followed.
        ScanRule(
            id: "julia.compiled",
            category: .julia,
            target: .children("~/.julia/compiled"),
            risk: .safe
        ),
        // The General registry clone — re-cloned by Pkg on the next
        // update.
        ScanRule(
            id: "julia.registries",
            category: .julia,
            target: .children("~/.julia/registries"),
            risk: .safe
        ),
        // Installed packages in the user depot — review: every package
        // re-downloads from the registry.
        ScanRule(
            id: "julia.packages",
            category: .julia,
            target: .children("~/.julia/packages"),
            risk: .review
        ),

        // MARK: OCaml
        // opam's download cache and package index inside its root
        // (opam's docs: the root defaults to ~/.opam, with repo data
        // under ~/.opam/repo). Both regenerate on the next opam update
        // or install. The root's switch directories — the installed
        // compiler and libraries — are deliberately not swept.
        ScanRule(
            id: "ocaml.opam-download-cache",
            category: .ocaml,
            target: .children("~/.opam/download-cache"),
            risk: .safe
        ),
        ScanRule(
            id: "ocaml.opam-repo",
            category: .ocaml,
            target: .children("~/.opam/repo"),
            risk: .safe
        ),

        // MARK: Zig
        // Zig's global cache (zig's introspect module:
        // resolveGlobalCacheDir reads ZIG_GLOBAL_CACHE_DIR, then
        // $XDG_CACHE_HOME/zig, then ~/.cache/zig).
        ScanRule(
            id: "zig.cache",
            category: .zig,
            target: .children("${ZIG_GLOBAL_CACHE_DIR}"),
            risk: .safe
        ),

        // MARK: Nim
        // The compiler's nimcache root (nimc's docs:
        // $XDG_CACHE_HOME/nim/$projectname(_r|_d), i.e. ~/.cache/nim/...
        // by default) — one entry per project, regenerated on rebuild.
        ScanRule(
            id: "nim.cache",
            category: .nim,
            target: .children("${XDG_CACHE_HOME}/nim"),
            risk: .safe
        ),
        // Nimble's package directory (nimble's options module:
        // nimbleDir defaults to ~/.nimble, NIMBLE_DIR overrides) —
        // the whole tree is swept: installed packages plus the bin/
        // executables nimble installs alongside them, all of which
        // reinstall, hence review.
        ScanRule(
            id: "nim.nimble",
            category: .nim,
            target: .children("${NIMBLE_DIR}"),
            risk: .review
        ),

        // MARK: Crystal
        // The compiler cache (crystal's codegen/cache_dir.cr: the
        // candidates are CRYSTAL_CACHE_DIR, $XDG_CACHE_HOME/crystal,
        // ~/.cache/crystal and ~/.crystal). The compiler itself keeps
        // only the 10 most recently used entries.
        ScanRule(
            id: "crystal.cache",
            category: .crystal,
            target: .children("${CRYSTAL_CACHE_DIR}"),
            risk: .safe
        ),

        // MARK: Perl
        // CPAN's downloaded sources and build leftovers (CPAN's
        // FirstTime.pm: keep_source_where defaults to
        // <cpan_home>/sources and build_dir to <cpan_home>/build, with
        // cpan_home at ~/.cpan).
        ScanRule(
            id: "perl.cpan-sources",
            category: .perl,
            target: .children("~/.cpan/sources"),
            risk: .safe
        ),
        ScanRule(
            id: "perl.cpan-build",
            category: .perl,
            target: .children("~/.cpan/build"),
            risk: .safe
        ),

        // MARK: CocoaPods / Carthage
        ScanRule(
            id: "pods.cocoapods",
            category: .pods,
            target: .children("~/Library/Caches/CocoaPods"),
            risk: .safe
        ),
        ScanRule(
            id: "pods.carthage",
            category: .pods,
            target: .children("~/Library/Caches/org.carthage.CarthageCache"),
            risk: .safe
        ),
        ScanRule(
            id: "pods.spec-repos",
            category: .pods,
            target: .directory("~/.cocoapods/repos"),
            risk: .review
        ),

        // MARK: IDE
        ScanRule(
            id: "ide.jetbrains",
            category: .ide,
            target: .children("~/Library/Caches/JetBrains"),
            risk: .safe
        ),
        // Electron apps scatter their regenerable caches across sibling
        // directories named `*Cache*` (Cache, CachedData, Code Cache,
        // GPUCache, DawnCache… — the set verified against a real Code data
        // directory). The glob takes each as one entry; `Service
        // Worker/CacheStorage` stays out because the top-level name carries
        // no "Cache".
        ScanRule(
            id: "ide.vscode-cache",
            category: .ide,
            target: .glob("~/Library/Application Support/Code/*Cache*"),
            risk: .safe
        ),
        ScanRule(
            id: "ide.vscode-logs",
            category: .ide,
            target: .children("~/Library/Application Support/Code/logs"),
            risk: .safe
        ),
        ScanRule(
            id: "ide.cursor",
            category: .ide,
            target: .glob("~/Library/Application Support/Cursor/*Cache*"),
            risk: .safe
        ),
        // Review, not safe: this directory hosts user-installed Xcode source
        // editor extensions (.appex) alongside legacy plug-ins — software to
        // reinstall, not a cache to regenerate.
        ScanRule(
            id: "ide.xcode-plugins",
            category: .ide,
            target: .children("~/Library/Application Support/Developer/Shared/Xcode/Plug-ins"),
            risk: .review
        ),

        // MARK: Browsers
        // Cache paths follow the Chromium convention (<vendor cache dir>/<profile>/Cache);
        // Firefox keeps cache2 in the profile tree, so its whole cache root is taken instead.
        // `com.apple.*` is absent by design: Safari's cache is TCC-protected on macOS 26+,
        // where enumeration pops a system authorization dialog.
        ScanRule(
            id: "browser.chrome-cache",
            category: .browser,
            target: .glob("~/Library/Caches/Google/Chrome*/*/Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.chrome-code-cache",
            category: .browser,
            target: .glob("~/Library/Caches/Google/Chrome*/*/Code Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.chromium-cache",
            category: .browser,
            target: .glob("~/Library/Caches/Chromium/*/Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.chromium-code-cache",
            category: .browser,
            target: .glob("~/Library/Caches/Chromium/*/Code Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.edge-cache",
            category: .browser,
            target: .glob("~/Library/Caches/Microsoft Edge/*/Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.edge-code-cache",
            category: .browser,
            target: .glob("~/Library/Caches/Microsoft Edge/*/Code Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.brave-cache",
            category: .browser,
            target: .glob("~/Library/Caches/BraveSoftware/Brave-Browser/*/Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.brave-code-cache",
            category: .browser,
            target: .glob("~/Library/Caches/BraveSoftware/Brave-Browser/*/Code Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.arc-cache",
            category: .browser,
            target: .glob("~/Library/Caches/Arc/User Data/*/Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.arc-code-cache",
            category: .browser,
            target: .glob("~/Library/Caches/Arc/User Data/*/Code Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.opera-cache",
            category: .browser,
            target: .glob("~/Library/Caches/com.operasoftware.Opera/*/Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.opera-code-cache",
            category: .browser,
            target: .glob("~/Library/Caches/com.operasoftware.Opera/*/Code Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.firefox-cache",
            category: .browser,
            target: .children("~/Library/Caches/Firefox"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.qqbrowser-cache",
            category: .browser,
            target: .glob("~/Library/Caches/QQBrowser2/*/Cache"),
            risk: .safe
        ),
        // Every Chromium-based browser keeps a `Code Cache` beside `Cache`,
        // so the remaining ones mirror the chrome / edge / chromium pair.
        ScanRule(
            id: "browser.qqbrowser-code-cache",
            category: .browser,
            target: .glob("~/Library/Caches/QQBrowser2/*/Code Cache"),
            risk: .safe
        ),

        // MARK: Homebrew
        ScanRule(
            id: "brew.cache",
            category: .homebrew,
            target: .children("~/Library/Caches/Homebrew"),
            risk: .safe
        ),

        // MARK: System & App Caches
        //
        // No catch-all rule over ~/Library/Caches here on purpose: its children
        // include the browser and IDE caches that dedicated rules already
        // target, so the same bytes would be counted (and shown) twice. App
        // caches are reached per-app through the residue scan instead.
        ScanRule(
            id: "system.logs",
            category: .system,
            target: .children("~/Library/Logs"),
            risk: .safe
        ),
        ScanRule(
            id: "system.crashreporter",
            category: .system,
            target: .children("~/Library/Application Support/CrashReporter"),
            risk: .safe
        ),
        ScanRule(
            id: "system.saved-state",
            category: .system,
            target: .children("~/Library/Saved Application State"),
            risk: .safe
        ),
        // Caution, not safe: this is where macOS keeps the autosaved copy of
        // documents that were never written to disk — the state a crashed app
        // recovers from. It is not regenerable (the app cannot rebuild a draft
        // the user never saved), so it must not be swept by a default clean.
        // The directory is TCC-protected, so this cannot be inspected with a
        // plain listing; the reasoning is Apple's documented autosave model,
        // not a measurement.
        ScanRule(
            id: "system.autosave",
            category: .system,
            target: .children("~/Library/Autosave Information"),
            risk: .caution
        ),
        ScanRule(
            id: "system.ios-backups",
            category: .system,
            target: .children("~/Library/Application Support/MobileSync/Backup"),
            risk: .caution
        ),
        ScanRule(
            id: "system.itunes-ipsw",
            category: .system,
            target: .glob("~/Library/iTunes/*.ipsw"),
            risk: .review
        ),

        // MARK: Trash
        ScanRule(
            id: "trash.home",
            category: .trash,
            target: .children("~/.Trash"),
            risk: .caution
        )
    ]

    static let cliRules: [CLIRule] = [
        CLIRule(
            id: "cli.go-clean-cache",
            category: .go,
            executable: "go",
            arguments: ["clean", "-cache"],
            title: "go clean -cache",
            sizeHints: ["${GOCACHE}"]
        ),
        CLIRule(
            id: "cli.go-clean-modcache",
            category: .go,
            executable: "go",
            arguments: ["clean", "-modcache"],
            title: "go clean -modcache",
            risk: .review,
            sizeHints: ["${GOMODCACHE}/cache/download"]
        ),
        CLIRule(
            id: "cli.npm-cache",
            category: .node,
            executable: "npm",
            arguments: ["cache", "clean", "--force"],
            title: "npm cache clean --force",
            sizeHints: ["${npm_config_cache}/_cacache"]
        ),
        CLIRule(
            id: "cli.yarn-cache",
            category: .node,
            executable: "yarn",
            arguments: ["cache", "clean"],
            title: "yarn cache clean",
            sizeHints: ["${YARN_CACHE_FOLDER}"]
        ),
        CLIRule(
            id: "cli.pnpm-store",
            category: .node,
            executable: "pnpm",
            arguments: ["store", "prune"],
            title: "pnpm store prune",
            sizeHints: ["${npm_config_store_dir}"]
        ),
        CLIRule(
            id: "cli.bun-cache",
            category: .node,
            executable: "bun",
            arguments: ["pm", "cache", "rm"],
            title: "bun pm cache rm",
            sizeHints: ["${BUN_INSTALL_CACHE_DIR}"]
        ),
        CLIRule(
            id: "cli.dart-pub-cache",
            category: .flutter,
            executable: "dart",
            arguments: ["pub", "cache", "clean"],
            title: "dart pub cache clean",
            risk: .review,
            sizeHints: ["${PUB_CACHE}"]
        ),
        CLIRule(
            id: "cli.pip-cache",
            category: .python,
            executable: "pip3",
            arguments: ["cache", "purge"],
            title: "pip cache purge",
            sizeHints: ["${PIP_CACHE_DIR}"]
        ),
        CLIRule(
            id: "cli.uv-cache",
            category: .python,
            executable: "uv",
            arguments: ["cache", "clean"],
            title: "uv cache clean",
            sizeHints: ["${UV_CACHE_DIR}"]
        ),
        // The standard way to reclaim simulator space: devices whose runtime
        // is gone cannot boot, so deleting them loses nothing reachable. No
        // size hint — the freed bytes live inside device trees the path rules
        // deliberately do not enumerate whole.
        CLIRule(
            id: "cli.sim-delete-unavailable",
            category: .simulator,
            executable: "xcrun",
            arguments: ["simctl", "delete", "unavailable"],
            title: "xcrun simctl delete unavailable",
            risk: .review,
            sizeHints: []
        ),
        CLIRule(
            id: "cli.brew-cleanup",
            category: .homebrew,
            executable: "brew",
            arguments: ["cleanup", "--prune=all", "-s"],
            title: "brew cleanup --prune=all -s",
            sizeHints: ["~/Library/Caches/Homebrew"]
        ),
        CLIRule(
            id: "cli.pod-cache",
            category: .pods,
            executable: "pod",
            arguments: ["cache", "clear", "--all"],
            title: "pod cache clear --all",
            risk: .review,
            sizeHints: ["~/Library/Caches/CocoaPods"]
        ),
        CLIRule(
            id: "cli.gradle-cache",
            category: .android,
            executable: "gradle",
            arguments: ["--stop"],
            title: "gradle --stop",
            risk: .review,
            sizeHints: []
        ),
        // RubyGems' own cleanup: drops old versions of every installed
        // gem, keeping the newest of each. Global, unlike
        // `bundle clean --force`, which needs a project to run in.
        CLIRule(
            id: "cli.gem-cleanup",
            category: .ruby,
            executable: "gem",
            arguments: ["cleanup"],
            title: "gem cleanup",
            sizeHints: ["${GEM_HOME}"]
        ),
        CLIRule(
            id: "cli.composer-clear-cache",
            category: .php,
            executable: "composer",
            arguments: ["clear-cache"],
            title: "composer clear-cache",
            sizeHints: ["${COMPOSER_CACHE_DIR}"]
        ),
        // NuGet's own commands (the `dotnet nuget locals` reference):
        // the http-cache clear is safe; global-packages forces every
        // project to restore again.
        CLIRule(
            id: "cli.dotnet-nuget-http-cache",
            category: .dotnet,
            executable: "dotnet",
            arguments: ["nuget", "locals", "http-cache", "--clear"],
            title: "dotnet nuget locals http-cache --clear",
            sizeHints: ["${NUGET_HTTP_CACHE_PATH}"]
        ),
        CLIRule(
            id: "cli.dotnet-nuget-global-packages",
            category: .dotnet,
            executable: "dotnet",
            arguments: ["nuget", "locals", "global-packages", "--clear"],
            title: "dotnet nuget locals global-packages --clear",
            risk: .review,
            sizeHints: ["${NUGET_PACKAGES}"]
        ),
        // Crystal's own cache clear (`crystal clear_cache`).
        CLIRule(
            id: "cli.crystal-clear-cache",
            category: .crystal,
            executable: "crystal",
            arguments: ["clear_cache"],
            title: "crystal clear_cache",
            sizeHints: ["${CRYSTAL_CACHE_DIR}"]
        )
    ]
}
