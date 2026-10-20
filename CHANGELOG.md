# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Auto-update no longer leaves the menu bar on the old version: the tray agent is a separate process embedded in the app bundle, and Sparkle only relaunches the main app, so a resident agent kept running the previous build's code until the next login. The main app now records its bundle version at every launch and restarts the agent when the bundle was replaced since the previous launch — a Sparkle update, a reinstall over an older copy, or a downgrade
- Auto-update no longer requires checking by hand: Sparkle's scheduled check only runs when a day has passed since the last one, so launches inside that window checked nothing and a newly published version went unnoticed. A background check now runs at every launch, and a found update is offered in the standard update alert instead of being downloaded and installed silently on quit — the auto-download switch still offers that hands-off mode for anyone who wants it

## [1.0.3] - 2026-10-20

A second cleanup feature aimed at everyday Mac users, plus a brand pass across the whole app.

### Added

- General cleanup module: a dedicated page (new sidebar row, directly under "All Items") with one big "cleanable files" number, rule rows grouped into system junk and browsing junk, each row showing its size and safety level (very clean / recommended / caution). Rows arrive pre-checked up to "recommended" — caution rows (Trash, Downloads installers, iOS backups) stay unchecked until the user opts in — and cleaning still goes through the confirmation sheet
- New coverage under the general module: browser caches (Chrome family, Chromium, Edge, Brave, Arc, Opera, Firefox, QQ Browser), useless language files inside app bundles (`LanguageFileScanner` — only ever removes whole `.lproj` directories to keep code signatures valid, whitelisting Chinese in any variant, English and Base), and installers and archives in `~/Downloads` (`DownloadsScanner`)
- App caches can now be swept without uninstalling: the residue scan splits an app's leftovers into regenerable junk (caches, HTTP storages, WebKit data) that belongs to the general module, while data (preferences, Application Support, containers, cookies) stays with the app in the uninstall flow, where deleting it is the user's explicit intent
- The general cleanup's row selection can be remembered: when a curation differs from what the next scan would pre-check, the confirmation sheet asks whether to keep it (defaulted on), and later scans pre-check exactly those rows
- Menu bar memory ranking: a quit button on each running app's row, with the warning drawn by the panel the moment the pointer reaches the controls
- Settings: a menu bar logo switch
- Lemon-style brand language across the app: the warm palette, the green call-to-action button with its press-scale response, the shared hero prompt, the gradient scan ring with its sweep arc, and the draw-in success mark — the welcome page and the general module's empty state now share one front-door composition
- `Scripts/build-all.sh`: one-command release pipeline (tag, build, sign, notarize, DMG, appcast, GitHub release)

### Changed

- The two cleanup features are now fully disjoint: the catch-all rules that made browser and IDE caches count twice (`system.user-caches`, `system.container-caches`) are gone, redundant sibling rules (`system.diagnostic`, `sim.logs`, `ide.vscode-cacheddata`) removed, and discovery deduplicates by path so an app's log directory is listed once
- General cleanup layout: the clean button moved into the page header beside the scan button (the header sits outside the scroll area so both stay reachable), the bottom-of-page button is gone, and the scan progress title is scoped per cleanup mode — the junk page no longer claims it is scanning caches
- Rule rows adopt a right-hand layout: the total and the safety level share one baseline ("434.6 MB, very clean"), groups get their own symbols, and pill badges are replaced by tinted level text
- Menu bar panel values are drawn smaller (16pt reclaimable size, 17pt CPU / memory / temperature) so the panel reads more compactly
- Animations are one-shot or scan-bound — ambient loops cost real CPU in a hidden-title-bar window — and all honor Reduce Motion
- Documentation and build scripts moved to English; the Chinese README was dropped in favour of the in-app language switch

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
