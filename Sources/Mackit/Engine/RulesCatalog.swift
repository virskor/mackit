import Foundation

/// The catalog of junk cleaning rules. All paths start with `~` and are expanded at runtime.
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
        ScanRule(
            id: "xcode.docs",
            category: .xcode,
            target: .children("~/Library/Developer/Xcode/DocumentationCache"),
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
            target: .children("~/.gradle/caches"),
            risk: .safe
        ),
        ScanRule(
            id: "android.gradle-wrapper",
            category: .android,
            target: .children("~/.gradle/wrapper/dists"),
            risk: .safe
        ),
        ScanRule(
            id: "android.gradle-daemon-logs",
            category: .android,
            target: .glob("~/.gradle/daemon/*/*.log"),
            risk: .safe
        ),
        ScanRule(
            id: "android.android-cache",
            category: .android,
            target: .children("~/.android/build-cache"),
            risk: .safe
        ),
        ScanRule(
            id: "android.studio-caches",
            category: .android,
            target: .glob("~/Library/Caches/Google/AndroidStudio*/*"),
            risk: .safe
        ),
        ScanRule(
            id: "android.konan",
            category: .android,
            target: .children("~/.konan"),
            risk: .safe
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
            target: .children("~/Library/Caches/go-build"),
            risk: .safe
        ),
        ScanRule(
            id: "go.mod-download",
            category: .go,
            target: .children("~/go/pkg/mod/cache/download"),
            risk: .safe
        ),
        // MARK: Node / Frontend
        ScanRule(
            id: "node.npm-cacache",
            category: .node,
            target: .children("~/.npm/_cacache"),
            risk: .safe
        ),
        ScanRule(
            id: "node.yarn-cache",
            category: .node,
            target: .children("~/Library/Caches/Yarn"),
            risk: .safe
        ),
        ScanRule(
            id: "node.yarn-berry",
            category: .node,
            target: .children("~/.yarn/berry/cache"),
            risk: .safe
        ),
        ScanRule(
            id: "node.pnpm-store",
            category: .node,
            target: .directory("~/Library/pnpm/store"),
            risk: .safe
        ),
        ScanRule(
            id: "node.pnpm-cache",
            category: .node,
            target: .children("~/Library/Caches/pnpm"),
            risk: .safe
        ),
        ScanRule(
            id: "node.bun-cache",
            category: .node,
            target: .children("~/Library/Caches/bun"),
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
        ScanRule(
            id: "node.eslint",
            category: .node,
            target: .directory("~/.cache/eslint"),
            risk: .safe
        ),
        ScanRule(
            id: "node.deno",
            category: .node,
            target: .children("~/.cache/deno"),
            risk: .safe
        ),

        // MARK: Flutter / Dart
        ScanRule(
            id: "flutter.pub-hosted",
            category: .flutter,
            target: .children("~/.pub-cache/hosted"),
            risk: .safe
        ),
        ScanRule(
            id: "flutter.pub-git",
            category: .flutter,
            target: .children("~/.pub-cache/git"),
            risk: .safe
        ),
        ScanRule(
            id: "flutter.pub-temp",
            category: .flutter,
            target: .children("~/.pub-cache/.temp"),
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
            target: .children("~/.pub-cache/bin"),
            risk: .review
        ),

        // MARK: Rust
        ScanRule(
            id: "rust.registry-cache",
            category: .rust,
            target: .children("~/.cargo/registry/cache"),
            risk: .safe
        ),
        ScanRule(
            id: "rust.registry-src",
            category: .rust,
            target: .children("~/.cargo/registry/src"),
            risk: .safe
        ),
        ScanRule(
            id: "rust.git-db",
            category: .rust,
            target: .children("~/.cargo/git/db"),
            risk: .safe
        ),

        // MARK: Python
        ScanRule(
            id: "python.pip-cache",
            category: .python,
            target: .children("~/Library/Caches/pip"),
            risk: .safe
        ),
        ScanRule(
            id: "python.uv-cache",
            category: .python,
            target: .children("~/.cache/uv"),
            risk: .safe
        ),
        ScanRule(
            id: "python.poetry-cache",
            category: .python,
            target: .children("~/Library/Caches/pypoetry"),
            risk: .safe
        ),
        ScanRule(
            id: "python.precommit",
            category: .python,
            target: .children("~/.cache/pre-commit"),
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
        ScanRule(
            id: "ide.vscode-cache",
            category: .ide,
            target: .glob("~/Library/Application Support/Code/Cache*"),
            risk: .safe
        ),
        // CachedData has no rule of its own: the Cache* glob above already
        // takes it as one entry, and its children are opaque hash names that
        // read as noise in the list anyway.
        ScanRule(
            id: "ide.vscode-logs",
            category: .ide,
            target: .children("~/Library/Application Support/Code/logs"),
            risk: .safe
        ),
        ScanRule(
            id: "ide.cursor",
            category: .ide,
            target: .glob("~/Library/Application Support/Cursor/Cache*"),
            risk: .safe
        ),
        ScanRule(
            id: "ide.xcode-plugins",
            category: .ide,
            target: .children("~/Library/Application Support/Developer/Shared/Xcode/Plug-ins"),
            risk: .safe
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
            id: "browser.arc-cache",
            category: .browser,
            target: .glob("~/Library/Caches/Arc/User Data/*/Cache"),
            risk: .safe
        ),
        ScanRule(
            id: "browser.opera-cache",
            category: .browser,
            target: .glob("~/Library/Caches/com.operasoftware.Opera/*/Cache"),
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
        ScanRule(
            id: "system.autosave",
            category: .system,
            target: .children("~/Library/Autosave Information"),
            risk: .safe
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
            sizeHints: ["~/Library/Caches/go-build"]
        ),
        CLIRule(
            id: "cli.go-clean-modcache",
            category: .go,
            executable: "go",
            arguments: ["clean", "-modcache"],
            title: "go clean -modcache",
            risk: .review,
            sizeHints: ["~/go/pkg/mod/cache/download"]
        ),
        CLIRule(
            id: "cli.npm-cache",
            category: .node,
            executable: "npm",
            arguments: ["cache", "clean", "--force"],
            title: "npm cache clean --force",
            sizeHints: ["~/.npm/_cacache"]
        ),
        CLIRule(
            id: "cli.yarn-cache",
            category: .node,
            executable: "yarn",
            arguments: ["cache", "clean"],
            title: "yarn cache clean",
            sizeHints: ["~/Library/Caches/Yarn"]
        ),
        CLIRule(
            id: "cli.pnpm-store",
            category: .node,
            executable: "pnpm",
            arguments: ["store", "prune"],
            title: "pnpm store prune",
            sizeHints: ["~/Library/pnpm/store"]
        ),
        CLIRule(
            id: "cli.bun-cache",
            category: .node,
            executable: "bun",
            arguments: ["pm", "cache", "rm"],
            title: "bun pm cache rm",
            sizeHints: ["~/Library/Caches/bun"]
        ),
        CLIRule(
            id: "cli.dart-pub-cache",
            category: .flutter,
            executable: "dart",
            arguments: ["pub", "cache", "clean"],
            title: "dart pub cache clean",
            risk: .review,
            sizeHints: ["~/.pub-cache"]
        ),
        CLIRule(
            id: "cli.pip-cache",
            category: .python,
            executable: "pip3",
            arguments: ["cache", "purge"],
            title: "pip cache purge",
            sizeHints: ["~/Library/Caches/pip"]
        ),
        CLIRule(
            id: "cli.uv-cache",
            category: .python,
            executable: "uv",
            arguments: ["cache", "clean"],
            title: "uv cache clean",
            sizeHints: ["~/.cache/uv"]
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
        )
    ]
}
