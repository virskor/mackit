<div align="center">

<img src="Sources/Mackit/Resources/sparkle-blue.png" width="120" alt="Mackit icon">

# Mackit

**A macOS developer cache cleaner** — scan every regenerable cache your toolchain leaves behind, pick items one by one with clear risk labels, and take your disk space back.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-1f88d8?style=flat-square&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://www.swift.org/)
[![License](https://img.shields.io/badge/license-MIT-3da639?style=flat-square)](LICENSE)
[![Release](https://img.shields.io/github/v/release/virskor/mackit?style=flat-square)](https://github.com/virskor/mackit/releases)
[![Downloads](https://img.shields.io/github/downloads/virskor/mackit/total?style=flat-square)](https://github.com/virskor/mackit/releases)

[English](README.md) · [简体中文](README_ZH.md)

🌐 [Official Website](https://www.mingcui.cn/mackit/)

</div>

---

## Why Mackit

Go, Node, Yarn, pnpm, Dart, Flutter, Rust, Python, CocoaPods, Gradle, Xcode, Android Studio… every one of these tools leaves **regenerable caches** on your machine: package downloads, build intermediates, module caches, simulator data, tool indexes. None of them look big alone; together they add up to tens of gigabytes. And in Finder they hide across a dozen dot-directories where you can neither see their size nor safely delete them.

What Mackit does:

1. **Scan** — concurrently enumerates 60+ rules to find caches, build artifacts and leftover files wherever they live, streaming results so sizes appear while the scan is still running;
2. **Label** — every item carries a risk level (Safe / Careful / Caution) and its full path, so you know what happens before you delete;
3. **Pick** — nothing is checked by default; you choose item by item, or select all "safe" items in one move;
4. **Delete** — move to Trash (reversible) or delete permanently; command-line items invoke the tools' own clean commands.

## Features

- **One-click scan**: 60+ path rules + 12 command-line clean rules, streamed into the list while the scan is still running
- **Three risk levels**: `Safe` (pure cache, recreated by the tool) / `Careful` (needs re-download or rebuild) / `Caution` (Trash, iOS backups, etc. — extra confirmation required)
- **App uninstall**: scans installed apps in `/Applications` and `~/Applications` together with their leftovers in `~/Library` (app support, caches, containers, preferences, login items…); running apps are refused
- **Build artifact scan**: point it at a directory (e.g. `~/Projects`) to find `node_modules`, `build`, `Pods`, `.dart_tool`, `DerivedData`, `target`, `.venv` and other rebuildable folders
- **Command-line cleaning**: `go clean -cache`, `npm cache clean`, `brew cleanup`, `dart pub cache clean`, etc.
- **Menu bar panel**: a resident menu bar icon opens a panel with reclaimable space, CPU / memory / temperature, per-app memory ranking with one-tap "free memory", free disk space and a CPU graph
- **Desktop stats overlay**: an optional always-on-top bar showing CPU / memory / temperature compactly, readable on any wallpaper, draggable with position memory, living only in the tray process
- **Hardware info**: model, disks, battery and other static information
- **Native UI**: SwiftUI sidebar + table + toolbar with native context menus, keyboard shortcuts, search and click-to-sort column headers
- **Localized**: Simplified Chinese / English / Traditional Chinese, follows the system language by default
- **Safety rails**: built-in protected-path list; system directories and the keychain are always refused

## Screenshot

![Mackit main window](docs/images/main-window-en.png)

> Screenshots of the menu bar panel, desktop overlay and hardware page are still to come.

## Installation

### Download a prebuilt binary (recommended)

Grab the latest DMG from [Releases](https://github.com/virskor/mackit/releases), open it and drag Mackit into Applications.

- Universal binary (arm64 + x86_64) for both Apple silicon and Intel Macs
- Requires macOS 14 or later (Intel machines must be able to run macOS 14)
- First install via DMG; later updates via in-app Sparkle auto-update

### Build from source

Requires macOS 14+ and Xcode 16+ (Swift 6):

```bash
git clone https://github.com/virskor/mackit.git
cd mackit

# Option 1: build and launch in one step (debug, fastest iteration)
./run.sh

# Option 2: build a release Mackit.app, then launch
Scripts/build-app.sh release
open Mackit.app
```

You can also open `Package.swift` in Xcode and run the `Mackit` scheme. Development builds compile for the native architecture only; the distributable universal binary (arm64 + x86_64) is covered in the [release notes](docs/RELEASE.md).

Run the tests:

```bash
swift test
```

## Usage

1. The first launch scans automatically; **nothing is checked by default** — you decide what to delete
2. Browse by category in the sidebar, or search items / paths from the toolbar
3. Add your code roots under "Settings › Project directories" to scan for build artifacts like `node_modules`
4. To uninstall an app: right-click the app row in the "Apps" category → "Uninstall with leftover files…" (or "Clean leftover files only…")
5. After checking items, click "Clean X GB" in the toolbar; the confirmation panel lists the details and risk notes
6. Keep "Move to Trash" enabled and empty the Trash only after you're sure

Keyboard shortcuts:

| Shortcut | Action |
| --- | --- |
| `⌘R` | Rescan |
| `⌘⌫` | Clean selected |
| `⌘⌥S` | Select all safe items |
| `⌘,` | Settings |

## Coverage

| Category | Contents |
| --- | --- |
| Apps | Installed apps in `/Applications` and `~/Applications`, plus their leftovers in `~/Library` (app support, caches, containers, preferences, ByHost, window state, HTTP storage, WebKit, cookies, app scripts, login items, logs, crash reports) |
| Build artifacts | node_modules, build, Pods, .gradle, .dart_tool, DerivedData, dist, target, .venv, __pycache__, etc. |
| Xcode | DerivedData, Archives, iOS/watchOS DeviceSupport, DocumentationCache, module caches |
| Simulators | dyld caches, in-device app caches, device temp dirs, simulator logs |
| Android / Gradle | Gradle caches, wrapper distributions, daemon logs, Android Studio caches, Kotlin/Native, Maven repo |
| Node / frontend | npm `_cacache`, Yarn, pnpm store, Bun, node-gyp, TypeScript, ESLint, Deno |
| Flutter / Dart | pub-cache (hosted / git / temp), Dart Analysis Server |
| Go | go-build cache, module download cache |
| Rust | cargo registry cache/src, git dependencies |
| Python | pip, uv, Poetry, pre-commit caches |
| CocoaPods | CocoaPods cache, Carthage cache, spec repos |
| IDEs | JetBrains, VS Code / Cursor caches and logs |
| Homebrew | download cache |
| System & apps | `~/Library/Caches`, sandboxed app caches, logs, crash reports, iOS backups |
| Trash | files in `~/.Trash` |

Command-line clean items are grouped under their tool's category, shown alongside the corresponding path rules.

### App uninstall

The "Apps" category is produced together with the main scan. Each app takes one row in the table showing its real icon, version, size and leftover-file count; every leftover file is also an independent row that can be checked on its own. Right-clicking an app row offers two shortcuts:

- **Uninstall with leftover files…**: checks the app itself plus all of its leftover files and opens the clean confirmation
- **Clean leftover files only…**: cleans leftovers, keeps the app

Uninstalling reuses the unified clean flow: both the app and its leftover files follow the "Settings › Clean method" setting — move to Trash (reversible) or delete permanently. Running apps are refused, with a result note asking you to quit them first. Leftover files are labeled by location — caches and logs are "Safe"; app support, preferences, containers and other places that may hold user data are "Careful".

If only the app itself is checked, the clean confirmation panel points out how many associated files are still unchecked (count and size per app) and offers a "Select all" shortcut, so you don't end up with an empty shell of a directory and the caches still on disk.

Known limitations: Group Containers (requires reading per-app entitlements), app-bundled uninstallers and system-level LaunchAgents/Daemons (need admin rights) are not covered; apps installed in custom locations discovered via a full Spotlight scan are out of scope as well.

## Permissions

Mackit needs to read `~/Library`, `~/.pub-cache`, `~/.gradle`, `/Applications` and similar locations, so the **App Sandbox is not enabled**. Some paths under `~/Library` require Full Disk Access, which the user can grant manually under "System Settings › Privacy & Security › Full Disk Access". Opening a path in Terminal requests the Apple Events permission to control Terminal (`NSAppleEventsUsageDescription`). "Free memory" in the tray panel requests admin authorization and runs `purge` (drops the file cache; does not affect the memory apps themselves hold). CPU, memory and per-app memory come from public system interfaces (`host_statistics64`, `proc_pid_rusage`); macOS has no public temperature API, so the temperature shown is the system thermal state.

## Development

### Architecture: main app + tray agent

Mackit is two processes from one binary, shipped in two bundles that switch roles by bundle ID:

| | Mackit.app (`cn.mingcui.mackit`) | MackitAgent.app (`cn.mingcui.mackit.agent`) |
| --- | --- | --- |
| Form | regular, has a Dock icon | LSUIElement, menu bar only |
| Role | main window, scanning, cleaning, settings, Sparkle updates | menu bar icon and panel, desktop stats overlay, system monitoring |
| Lifecycle | quits when the window closes | resident; a login item launches it at login |

**Closing the main window = the main process exits = the Dock icon disappears, while the menu bar monitoring keeps ticking every minute** — that is how "window closed but the tray lives on" is implemented, without any activation policy switching at runtime (switching between regular and accessory at runtime makes macOS rebuild the menu bar and add/remove Dock tiles every time, which is exactly why the menu bar flickers and the Dock row shifts).

How the two processes cooperate (`Sources/Mackit/IPC/`):

- **Commands**: the agent sends distributed notifications (open window / settings / hardware / clean / quit / toast); if the main app isn't running, commands are persisted to disk first and replayed after it launches (cold-start compensation)
- **State**: the main app broadcasts scan / clean state to the agent, so the panel header can show "reclaimable size" and the checked count; monitoring data in turn is polled by the agent alone — it must keep ticking after the main app exits
- **Settings**: shared file `~/Library/Application Support/Mackit/shared-settings.plist`, written by the main app and read by the agent, with a broadcast refresh on change. App Groups are not used: under ad-hoc signing the Group Container cannot be resolved (cfpregs reports `Container: (null)` and the whole source gets detached), which only recovers with a paid Developer ID signature — development iteration must not depend on a certificate
- **Login item**: registers the agent (`SMAppService.loginItem`), so login only shows the menu bar icon; the main app relaunches the agent if it's missing, and watches over it every 30 seconds while running (the tray self-heals after an agent crash)
- **Single instance**: only one agent per bundle ID is allowed — registering the login item makes launchd pull one up in the same instant, so if the main app had already started one, two tray icons would appear; the later instance yields when it sees its predecessor
- **Residency**: the agent's Info.plist disables `NSSupportsAutomaticTermination` / `NSSupportsSuddenTermination`, and it calls `disableAutomaticTermation` at launch

### macOS 14 compatibility

The floor is the compile target macOS 14: no source uses APIs above 14.0 (`swift build` reports zero availability warnings against the 14.0 target). The only symbol that needs the macOS 15.0+ runtime, `withTaskGroup(of:returning:isolation:body:)`, is compiled in with weak linking plus a runtime version check, falling back to a local implementation on 14.x, so no missing symbol is ever resolved. The hardware page and menu bar monitoring use the same public interfaces on Apple silicon and Intel (`HardwareSampler` degrades gracefully when Intel has no perf levels).

### Localization

All user-facing strings live in `Sources/Mackit/Resources/Localizable.xcstrings` (String Catalog), with Simplified Chinese as the source language plus English and Traditional Chinese translations. No user-facing literals appear in code; everything goes through `Utilities/L10n.swift`:

```swift
Text(verbatim: L10n.tr("toolbar.rescan"))                 // static string
Text(verbatim: L10n.fmt("toast.trashed", item.title))     // with placeholders: %@ / %lld
Text(verbatim: L10n.items(count))                         // "N items", plural handled
```

To add a language: open the catalog in Xcode, click `+` at the bottom left and translate — no code changes needed. New strings are added as keys in the catalog; `LocalizationTests` in the test suite checks key completeness and placeholder consistency against the call sites.

Interface language selection lives in `Utilities/AppLanguage.swift`: "Follow system" plus three languages, stored in UserDefaults under `appLanguage` and mirrored into the app domain's `AppleLanguages` — CFBundle's string lookup reads that key, so it takes effect after a restart (Sparkle's update UI and system file panels follow too). Why a restart instead of an in-process switch: scan result titles and descriptions are frozen in the current language when created, so an in-process refresh would only produce a mixed-language list (see the source comments for details).

The two plural keys (`.one` / `.other`) must keep the same placeholder layout — `.one` needs `%lld` too, with only the noun made singular; otherwise `%@` receives an integer and the UI crashes on first render.

### Logging

Lifecycle events (scan / clean start, completion, cancellation, failure) and window-shape changes all go through a unified `os.Logger` (subsystem = bundle ID), recorded in release builds too. Each process logs under its own subsystem: `cn.mingcui.mackit` for the main app, `cn.mingcui.mackit.agent` for the tray agent. Watch live:

```bash
log stream --predicate 'subsystem == "cn.mingcui.mackit"' --level info
# tray agent logs (launch, relaunch, watchkeeping)
log stream --predicate 'subsystem == "cn.mingcui.mackit.agent"' --level info
# per-directory enumeration details (which unreadable dirs were skipped): add --level debug
```

Filter by subsystem in the Console app. Only counts, sizes, durations and rule ids are logged — never file contents.

### Project structure

```
Sources/Mackit/
├── MackitApp.swift               # entry dispatch (@main switches role by bundle ID) + main window/menu + shared AppDelegate
├── AgentApp.swift                # tray agent entry (MenuBarExtra + labels)
├── Models/                       # data models: items, categories, risk levels, scan rules, comparators
├── Engine/
│   ├── RulesCatalog.swift        # 60+ scan rules and 12 CLI clean commands
│   ├── AppScanner.swift          # installed-app discovery and leftover detection
│   ├── FileSystem.swift          # size computation, globbing, tool lookup, volume capacity
│   ├── Scanner.swift             # concurrent scanning + project directory traversal
│   └── Cleaner.swift             # delete / trash / command execution
├── Monitor/                      # CPU / memory / thermal sampling, hardware info, memory release
├── IPC/                          # inter-process command / state / settings channels (distributed notifications + shared plist)
├── Updater/
│   └── UpdateController.swift    # Sparkle auto-update
├── ViewModels/
│   └── AppViewModel.swift        # state machine: scan, selection, clean, settings (one per process)
├── Views/                        # SwiftUI: main window, tray panel, overlay, settings, hardware page
│   └── Components/               #   reusable components (badges, progress ring, notice rows, flow layout…)
└── Utilities/
    ├── AppLanguage.swift         # interface language selection (system + three languages, writes AppleLanguages)
    ├── MackitLog.swift           # unified os.Logger wrapper
    ├── Formatters.swift          # byte and time formatting
    ├── LaunchAtLogin.swift       # login item registration (points at the embedded MackitAgent.app)
    └── L10n.swift                # localization lookup (String Catalog)
    Resources/
    ├── Localizable.xcstrings     # three languages (zh-Hans / en / zh-Hant)
    └── sparkle-blue.png          # brand icon (shared by in-app display and the app icon)
Scripts/                          # build / packaging / icon generation scripts
Tests/MackitTests/                # 22 test files
```

### Tests

`swift test`. 22 test files cover the scan engine, clean engine, rule catalog, app uninstall, shared storage, sort comparators, localization key integrity, the update controller and more.

### Releasing

Signing, notarization, DMG packaging and the Sparkle update pipeline are maintainer-facing; see [docs/RELEASE.md](docs/RELEASE.md).

## Contributing

Issues and PRs are welcome. Build, test and code conventions: [CONTRIBUTING.md](CONTRIBUTING.md). By participating you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security

Private keys, certificates and credentials **never enter the repo**: `secrets/` and all `*.p8` / `*.pem` / `*.key` files are blocked by `.gitignore`, and the pre-commit hook (installed via `Scripts/install-git-hooks.sh`) scans the staging area to intercept private keys. Please do not open public issues for security problems — report them privately via GitHub Security Advisory.

## License

[MIT](LICENSE) © 2026 virskor

## Acknowledgments

- [Sparkle 2](https://sparkle-project.org/) — in-app auto-update
