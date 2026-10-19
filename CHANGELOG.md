# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] - 2026-10-19

### Changed

- About section: the website link now opens the official site (`https://www.mingcui.cn/mackit/`), and a new GitHub repository link (`https://github.com/virskor/mackit`) was added next to it — both localized in Simplified Chinese, English and Traditional Chinese

### Added

- `AGENTS.md`: contributor guidance covering the build/test workflow, code conventions and the English-first rule for development artifacts
- `docs/release-notes/`: per-release notes, alongside the maintainer-facing release procedure in `docs/RELEASE.md`

## [1.0.1] - 2026-10-19

Release-pipeline verification build — the application itself is unchanged from 1.0.0.

### Changed

- Update feed moved to GitHub Releases (`https://github.com/virskor/mackit/releases/latest/download/appcast.xml`), so the public repository can serve the appcast anonymously
- The update archive and `appcast.xml` now ship with every Release, letting 1.0.0 users upgrade in-app
- Developer ID signing, notarization and stapling verified end to end; the downloaded app opens with no Gatekeeper warning
- `docs/RELEASE.md`: maintainer-facing notes on signing, notarization, DMG packaging and Sparkle update hosting

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

[1.0.2]: https://github.com/virskor/mackit/releases/tag/v1.0.2
[1.0.1]: https://github.com/virskor/mackit/releases/tag/v1.0.1
[1.0.0]: https://github.com/virskor/mackit/releases/tag/v1.0.0
