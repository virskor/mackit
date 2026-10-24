# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.8] - 2026-10-24

### Fixed

- The main window's traffic lights and system-styled controls now take the macOS 26+ appearance instead of the pre-macOS-26 one. SwiftPM stamps the linked binary's `LC_BUILD_VERSION` with the deployment target for both `minos` and `sdk`, so the app — built against the macOS 27 SDK — declared `sdk 14.0`, and AppKit read that as "a pre-macOS-26 app": the window drew the small traffic lights (12pt discs with glyphs always visible) and the old control metrics while every other current app on the system drew the macOS 26+ chrome (14pt discs with glyphs on hover, larger controls). `build-app.sh` now restates the SDK the build actually compiled against through the linker's `-platform_version`, keeping `minos` at the deployment target so the app still installs on macOS 14. Nothing in the app's own code changes; the window keeps its hidden title bar and full-bleed layout
- The sidebar keeps the macOS 26+ Liquid Glass instead of flattening into a plain gray. The window-level background painted `windowBackgroundColor` behind the whole `NavigationSplitView`, sidebar column included, so the sidebar's translucent glass sampled a flat opaque wall rather than the window's own glass backdrop and lost the specular gradient the system's sidebars wear; the sidebar footer's `.bar` material was a second opaque slab in the same column, reading as a lighter block under the list. Both backdrops now stay clear on macOS 26+ so the glass samples the window directly. Below 26 there is no glass to preserve and the window's backdrop is the plain window background color, so the legacy treatment is painted exactly as before — the gate is a runtime OS-version check rather than an SDK declaration, and the legacy branch runs on every launch on the floor OS

## [1.0.7] - 2026-10-23

### Changed

- macOS 26 and later now render the app's own surfaces in Liquid Glass instead of the hand-painted plates: the action toast, the clean-progress card, the treemap's hover label, the tray panel's quit hint and clean pill, the disk-analysis navigation chevrons and every brand call-to-action. `GlassSurface` owns the switch — one component decides between `glassEffect` (macOS 26+) and the exact fill, hairline and shadow each surface painted before — so macOS 14 and 15 keep the appearance they had, and the Liquid Glass pilot that `BrandCTAButton` carried as an opt-in is now the default everywhere the button appears, the results page's "Done" included. Glass replaces the fallback's hairline and shadow rather than stacking on them, and a disabled control stays on the flat fill, where a dimmed glass reads as broken rather than as "not now". System-styled controls — push buttons, switches, segmented pickers, the sidebar, tables, forms, progress views — follow the system's own macOS 26 appearance and are deliberately untouched

- The content toolbar's actions carry real weight. Scan, sort, the safe-only switch, the search field and the clean button all ran on default metrics, so a button in the hand-built row rendered at text-button weight beside the prominent clean button and the whole strip read as scaffolding. The actions now use explicit `.bordered` / `.button` styles at `.large` — the same treatment the results page already gave its rescan button — the switch steps up to `.regular`, the search field and the clean button grow to match, and the row gains height. Those styles are also what let the actions pick up the system's own macOS 26 surface, so the row reads as one piece on every OS rather than a styled button among naked ones

- The sidebar reads as one list. Every row is a single line at one height — the cleanup rows used to stack the item count under the title while the module entries were single-line, so a tall row and a short one alternated with no rule saying why — with the count folded in beside the size in a trailing slot every row has, filled or not, so the titles share one ragged edge. The figures hold their width when the sidebar narrows and the title gives way instead. The safe-only filter, the one control row, takes the same shape — icon, title, and its checkbox in the trailing slot where the figures sit — rather than hanging at the leading edge. The row-leading icons are larger (15pt in the sidebar, 13pt in the list), and the selected row is a light pill inset from the row's edges that darkens against the light sidebar and lightens against the dark one, with the row's own colors left alone; the 15% accent tint it replaces read as a hover state. The four module-entry rows were four copies of one layout; they are now calls to the single row builder

### Fixed

- The toolbar's sort menu names the sort in force instead of a fixed "Sort". The label was static, so after picking "earliest modified" the row still read "Sort" and the only trace of the choice was the checkmark inside the menu — the one place the user isn't looking. `sortComparator` is written by the table's header clicks as well as by the menu, so the live state is a comparator rather than a preset; `ItemSort` gained the reverse lookup (every comparator a header click can produce is one of the six presets), and the row now shows that preset's title, falling back to the generic label for a comparator no preset covers

## [1.0.6] - 2026-10-22

### Fixed

- Launch at login no longer dies silently after the agent binary is replaced. A login item registration caches a launch constraint computed from the agent binary at registration time — a code-directory hash for an ad-hoc-signed build, an identifier + team pair for a Developer-ID-signed one. Replacing the binary (a rebuild, an update, a reinstall) left that constraint pointing at a hash that no longer exists, so the kernel killed the agent at every login with a "Launch Constraint Violation", launchd removed the service on the spot, and the menu bar icon never appeared — the entry it left behind stopped resolving and a spawn retry failed every ten seconds, forever. The app now rebuilds the registration (unregister + register) at every main app launch when it is missing or was built from a different agent binary, tracked by the binary's cdhash, since a rebuild of the same commit changes the hash while leaving the version untouched. A registration still awaiting the user's approval in System Settings is left alone rather than churned on every launch
- The launch-at-login choice is persisted in shared settings instead of being read from the system registration, so a registration the system gave up on no longer silently flips the settings toggle off — the choice is lost exactly when it needs rebuilding. The system state remains the fallback for settings files written before the choice was stored (an upgrade)
- Turning launch at login off no longer kills the tray. Unregistering a login item makes launchd kill the process it spawned for it — the very menu bar icon the user was looking at — even though the setting only ever decided whether the agent starts at login. The agent is now brought back through LaunchServices after unregistering, whose instances the login item has no hold on, so the tray survives the toggle and only the login-time start is affected

### Changed

- The empty-state prompt is one composition instead of six hand-written variants: the welcome page, the general module's empty state and the disk analysis page's placeholders (unscanned, unreadable, protected) had drifted into six sets of metrics. `HeroPromptView` now owns the composition — badge, copy, optional hint, action with accessory, footer — at two scales, and callers only choose their subject

## [1.0.5] - 2026-10-22

### Added

- Disk space analysis: a new tool page (sidebar "Tools" section, below the cleanup entries) answering "where did the space go". The page opens on a start screen — a whole-disk traversal is minutes of IO, so it waits for the user's button instead of scanning on arrival — and once started, a scanning screen shows the folder being measured and a stop button while it runs, with the results appearing only after the scan has landed, so no number on screen is still moving. The left column lists the current directory's children with their recursive sizes and item counts, biggest first; the right column shows the selected folder's breakdown as a squarified treemap, with a toggle between the treemap and a plain list. Navigation is breadcrumb-based with back/forward history, and a toolbar shortcut jumps straight to the home folder — the fastest path to `~/Library/Containers`, where most reclaimable container junk lives. The scan retains six levels of the tree (measured on a real ~500 GB volume: six levels keep the footprint at tens of megabytes, where eight would hold over a million nodes); drilling past that scans the folder the same way — scanning screen first, results after — so `Users › … › Library › Containers › <container> › Data` stays reachable at any depth. The hardware page's "Analyze Disk Space" now opens this tool instead of running a cleanup scan
- The analysis page is honest about what it could not measure: a folder the process may not read (a denied permission prompt, or a locked directory) is reported as unreadable instead of claiming "0 B", and `~/Documents` / `~/Desktop` / `~/Downloads` are listed as "not scanned" rather than silently skipped — scanning one is an explicit action, so no access dialog interrupts a scan, and a link to the Full Disk Access pane is offered for a complete scan. Mount points and symlinks are left out entirely: their bytes are either another volume's or already counted through the firmlinks, and listing them would show a near-empty row for half the disk

### Changed

- The disk analysis scanning screen now answers "how much longer". It always shows the exact elapsed time, and the ring fills to a real percentage with a remaining-time estimate extrapolated from the measured rate. A filesystem walk's total is unknowable up front, so the first scan of a tree counts it concurrently: a readdir-only traversal — it never reads a file's inode, which is where the measurement spends its time — walks the root's subtrees on a few workers and lands about two fifths of the way into the measurement, at which point the ring switches from sweeping to filling. Measured on a real 65 k-directory tree, that count costs about a quarter of the measurement and slows it by roughly 13%, and it is remembered per tree, so every later scan divides by the remembered count directly instead of counting again. The estimate is keyed to the skip set, so approving `~/Documents` mid-session (which adds its whole subtree to the traversal) drops the stale denominator instead of stranding the ring at 100%, and small trees that never reach the sample floor simply show the elapsed time

- The disk analysis measurement now survives leaving the page. Switching to another sidebar row used to cancel it — and since a whole-disk scan drops the tree when it starts, the tool came back to its start screen with nothing to show, as if it had forgotten what it was doing. The scan belongs to the session rather than to the page being visible, so it keeps running while the user browses elsewhere and is there when they return; the sidebar's tool row shows a spinner meanwhile, so a background measurement is not invisible, and coming back attaches to the running scan instead of starting a second one. The page's stop button, the toolbar's rescan/stop and starting a different scan remain the only ways to end it

- Disk space analysis walks a tree about 40% faster, and neither of the two costs was the syscall itself. Every directory's progress tick went through an actor — 150 k directories meant 150 k suspension/resume pairs for what is two integers — and `FileSystem.entries` built a `URL` for every entry it returned, including the deep files the measurement only sums, whose path was then rebuilt from that URL as a string. Progress now counts under an unfair lock and entry paths are computed on demand: on `/System/Library` (150,592 directories, 32.8 GB) a scan takes 2.65 s instead of 4.6 s, measured back to back on the same cache, with identical output (32,827,998,208 bytes, same directory count). The readdir counting pass got the same treatment (3.4 s → 2.9 s), and there more workers was tried and does nothing — 6, 10 and 14 all land within 3%

- The disk analysis measurement runs on a fixed pool of workers over one shared queue, the design the counting pass already used, instead of spawning a task per directory. A task per directory is not bounded by the concurrency limit: a parent task stays alive waiting for its children however deep the tree runs, so the semaphore that capped concurrent enumerations capped nothing about how many tasks exist at once. On a real startup disk (1.7 M directories, 252 GB) that peaked at 871 k live tasks and 2.7 GB resident — measured, by counting them — and took 110 s; the same disk now peaks at 483 MB and takes 37 s, with the tree itself retained exactly as before (219,866 nodes). Output is unchanged: `/System/Library` still measures 32,827,998,208 bytes in 2.7 s. A deep, leaf-poor tree is the shape that grows a task-per-directory population fastest, and it is now the regression test's fixture

- Disk space analysis measures a directory with a single `getattrlistbulk` call (name, node type, allocated size and mount status in one syscall) instead of Foundation's `contentsOfDirectory` plus a `resourceValues` round trip per entry, and the separate readability probe, child-count pass and traversal first level are merged into one. Mount points are recognized by the kernel's own per-entry flag rather than diffing every path against the mount table, which is both cheaper and immune to firmlink spelling differences. Measured against a Foundation-based traversal on real trees, the sizes are identical while a 112 k-file cache directory measures in 0.45 s instead of 5.3 s and a fresh full-disk scan of a 1.7 M-directory startup disk (252 GB) completes in 37 s

- The treemap no longer turns a folder's small children into a field of unlabelled fragments. Area stays proportional for every child big enough to carry a name, and the rest — everything under about 57×57pt — is folded into a single "其余 N 项" tile occupying exactly the area those children add up to, which opens a list of all of them (still enterable, still revealable in Finder). A 51-child `Applications` list at a 660×500 card splits into 21 labelled tiles plus one aggregate block, in place of the corner of unlabelled fragments the same children used to produce, and the aggregate's size is the sum of what it holds rather than a rounded figure. Labels are now measured against the space a tile has rather than against a fixed threshold, so a name is drawn whole, truncated once, or not at all instead of wrapping mid-word ("元宝.ap" with a "p" underneath); a large tile carries its percentage of the folder beside its size; hovering a tile too small to read floats its name, size and percentage beside it; and the child-count limit that used to swap the whole map for a plain list is gone, so a `Frameworks` folder or a `node_modules` now shows its head plus one aggregate tile instead of nothing at all

### Fixed

- "Show in Finder" no longer starts an application. LaunchServices opens a resource with whatever application claims that kind of resource, so revealing an application bundle — every row and tile under `/Applications` — launched the app instead of showing it, and a preference pane opened System Settings; both claims were verified against LaunchServices before the fix, which reports the bundle itself for an `.app` and System Settings for a `.prefPane`. A folder is now opened directly only when Finder would open it, and anything else is revealed through its enclosing folder — the window the user asked for, without an app starting behind it. The junk list's reveal had the same shape and is fixed with it

## [1.0.4] - 2026-10-20

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

[1.0.8]: https://github.com/virskor/mackit/releases/tag/v1.0.8
[1.0.7]: https://github.com/virskor/mackit/releases/tag/v1.0.7
[1.0.6]: https://github.com/virskor/mackit/releases/tag/v1.0.6
[1.0.5]: https://github.com/virskor/mackit/releases/tag/v1.0.5
[1.0.4]: https://github.com/virskor/mackit/releases/tag/v1.0.4
[1.0.3]: https://github.com/virskor/mackit/releases/tag/v1.0.3
[1.0.2]: https://github.com/virskor/mackit/releases/tag/v1.0.2
[1.0.1]: https://github.com/virskor/mackit/releases/tag/v1.0.1
[1.0.0]: https://github.com/virskor/mackit/releases/tag/v1.0.0
