# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-19

First release. Mackit is a macOS developer cache cleaner: scan every regenerable cache your toolchain leaves behind, pick items one by one with clear risk labels, and take your disk space back.

### Added

**Scanning**

- 60+ path rules covering Go, Node/Yarn/pnpm/Bun, Dart/Flutter, Rust, Python (pip/uv/Poetry/pre-commit), CocoaPods/Carthage, Gradle/Android Studio, Xcode, simulators, JetBrains, VS Code/Cursor, Homebrew, `~/Library/Caches`, logs, crash reports, iOS backups and the Trash
- 12 command-line clean rules (`go clean -cache`, `npm cache clean`, `brew cleanup`, `dart pub cache clean`, …), grouped under their tool's category alongside the corresponding path rules
- Concurrent scanning with streaming results — sizes appear in the list while the scan is still running
- Build-artifact scan of custom project directories: `node_modules`, `build`, `Pods`, `.dart_tool`, `DerivedData`, `target`, `.venv`, `__pycache__` and other rebuildable folders

**Cleaning**

- Nothing is checked by default; pick item by item, or select all "Safe" items in one move (`⌘⌥S`)
- Three risk levels per item: `Safe` (pure cache, recreated by the tool), `Careful` (needs re-download or rebuild), `Caution` (Trash, iOS backups, etc. — extra confirmation required)
- Move to Trash (reversible) or delete permanently, per the "Clean method" setting
- Clean confirmation panel listing details and risk notes, including a per-app count and size of associated files still unchecked
- App uninstall: scans `/Applications` and `~/Applications` with their leftovers in `~/Library` (app support, caches, containers, preferences, ByHost, window state, HTTP storage, WebKit, cookies, app scripts, login items, logs, crash reports); right-click shortcuts for "Uninstall with leftover files…" and "Clean leftover files only…"; running apps are refused

**Menu bar and monitoring**

- Tray agent (`MackitAgent.app`, LSUIElement): resident menu bar icon with a panel showing reclaimable space, CPU / memory / temperature, per-app memory ranking with one-tap "free memory", free disk space and a CPU graph
- Desktop stats overlay: optional always-on-top bar with CPU / memory / temperature, readable on any wallpaper, draggable with position memory
- Hardware page: model, disks, battery and other static information
- Login item registration (`SMAppService.loginItem`) with agent self-healing (relaunch on crash, single-instance arbitration)

**Interface**

- Native SwiftUI sidebar + table + toolbar, context menus, keyboard shortcuts (`⌘R`, `⌘⌫`, `⌘⌥S`, `⌘,`), search and click-to-sort column headers
- Localized: Simplified Chinese / English / Traditional Chinese, follows the system language by default
- Toast notifications for tray-triggered actions

**Under the hood**

- Two-process architecture from one binary: main app (`cn.mingcui.mackit`) and tray agent (`cn.mingcui.mackit.agent`) switching roles by bundle ID, cooperating over distributed notifications plus a shared settings plist (cold-start command persistence, state broadcast, change-driven settings refresh)
- Unified `os.Logger` logging under each process's own subsystem, kept in release builds
- Sparkle 2 in-app auto-update (appcast + EdDSA signatures + code-signing verification)
- Safety rails: built-in protected-path list; system directories and the keychain are always refused
- Universal binary (arm64 + x86_64), macOS 14+ (no APIs above 14.0; the one macOS 15 symbol is weak-linked with a runtime fallback)
- 22 test files covering the scan engine, clean engine, rule catalog, app uninstall, shared storage, sort comparators, localization key integrity, the update controller and more

### Security

- Private keys, certificates and credentials never enter the repo (`secrets/`, `*.p8` / `*.pem` / `*.key` blocked by `.gitignore`); a pre-commit hook scans the staging area to intercept private keys

[1.0.0]: https://github.com/virskor/mackit/releases/tag/v1.0.0
