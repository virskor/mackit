# AGENTS.md

Guidance for AI coding agents working on Mackit.

## Language

**English is the primary language for all development work.** Code comments, commit messages, PR and issue descriptions, documentation, and review feedback are all written in English.

This applies to development artifacts only. User-facing product strings are content, not development language: they still go through the localization catalog (`Localizable.xcstrings`) in all three supported languages — Simplified Chinese, English, and Traditional Chinese.

## Project Overview

Mackit is a native macOS developer cache cleaner, written in Swift 6 with strict concurrency, targeting macOS 14+. It is a Swift Package containing two executables:

- `cn.mingcui.mackit` — the main app (windowed)
- `cn.mingcui.mackit.agent` — the menu bar agent, an `LSUIElement` process embedded as a LoginItem

Core areas: scan rules in `Engine/`, SwiftUI views in `Views/`, localization in `Resources/Localizable.xcstrings`, shared state between the two processes in `IPC/`.

## Build & Test

```bash
./run.sh           # Build debug and launch
./run.sh release   # Build release and launch
./run.sh debug -n  # Build only, no launch
swift test         # Run the test suite
```

A change is not complete until `swift build` and `swift test` both pass. Running the test suite requires explicit user approval — see [Test](#test).

## Code Conventions

- **Componentize the design** — split logic into focused, single-purpose components; reuse existing components instead of copying code; keep the codebase free of redundant code
- **Page layouts fill their container** — see [UI Layout](#ui-layout); a collapsed page passes every unit test and fails the first time it is seen
- **Swift 6 strict concurrency is enabled** — new code must pass concurrency checking; if an exemption is truly needed, explain why in a comment
- **Comments explain "why", not "what"** — constraints, trade-offs, and pitfalls are worth writing down; obvious logic does not need a comment
- **All user-facing strings go through localization** — no user-facing literals in code; use `L10n.tr` / `L10n.fmt` / `L10n.items` and add every string to `Localizable.xcstrings` in all three languages
- **Singular and plural keys (`.one` / `.other`) must use consistent placeholder layouts** — the `.one` string must also contain `%lld`, changing only the noun to its singular form, or the UI crashes on render
- Logging goes through `MackitLog` (`os.Logger`) — record counts, sizes, durations, and rule IDs only, never file contents
- New scan rules go in `Engine/RulesCatalog.swift`, following the organization of the existing rules
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:` / `fix:` / `docs:` / `refactor:` / `test:` / `chore:`

## Security

- Private keys, certificates, and credentials (`*.p8` / `*.pem` / `*.key` / `*.p12`, etc.) never go into the repository — `.gitignore` blocks them, and `Scripts/install-git-hooks.sh` installs a pre-commit hook as a safety net
- Credential management for the release pipeline is documented in [docs/RELEASE.md](docs/RELEASE.md)

## System Version Compatibility

The deployment target is macOS 14 while the build runs against newer SDKs, so every API above the floor is a crash risk on the systems that lack it. These are hard rules, not preferences:

- **Every API above the deployment target must be guarded** — wrap the call in `if #available(macOS X, *)` or annotate the declaration `@available`, and give the older path a real implementation. Never silence an availability error with an exemption, and never raise the deployment target to make a newer API compile
- **Availability is a runtime OS-version check, never an SDK declaration** — the binary's `LC_BUILD_VERSION` sdk field (restated by `Scripts/build-app.sh`) only decides which generation of system chrome the OS draws; it never makes a newer API safe to call. "We declare sdk 27, so macOS 26 APIs are fine" is always wrong
- **The floor is fixed** — `minos` 14.0 in the binary and `LSMinimumSystemVersion` 14.0 in both bundles are set by `Scripts/build-app.sh` from `MACOS_MINOS`; neither may be raised to silence an availability diagnostic
- **No force-unwrapping or implicitly-unwrapped optionals on system-versioned values** — use optional chaining, `guard let`, or a nil fallback. A force unwrap that only fails on one OS version is a crash only some users ever see, which makes it the worst kind
- **Every version-gated surface needs a fallback that actually runs on the floor** — `GlassSurface`'s `.fill(...)` path is the pattern to copy. A fallback that never executes on macOS 14 is not a fallback; if it cannot be exercised, say so instead of claiming it works
- **Newer-OS-only code must degrade, never crash or blank out** — the older path must keep the feature usable: a plainer visual treatment is fine, a missing view, an empty list, or a dead control is not
- **Builds must stay clean** — `./run.sh` and `Scripts/build-app.sh` builds complete with zero warnings; an availability warning is an unguarded API that has not crashed yet

## UI Layout

The window's detail area is a filled container and every page view lives inside it, but SwiftUI stacks size to their content by default. A page that does not claim the available height collapses into a thin strip floating above empty space — invisible in code review, obvious the moment the app runs. These are hard rules, not preferences:

- **Page views claim the full detail area** — the page's content region gets `.frame(maxWidth: .infinity, maxHeight: .infinity)` so it fills the card instead of hugging its content. `DiskAnalysisView`'s results and the Homebrew manager's sections are the pattern to copy
- **Transient states center inside the full area** — loading, empty, no-selection and not-installed states are `Spacer` pairs inside a frame that actually has height. A `Spacer` in a content-sized frame expands to zero, which is how a "centered" state ships as a top-anchored strip
- **Multi-column layouts fill vertically** — the column `HStack` gets `.frame(maxHeight: .infinity)`; fixed-width columns keep their width, the flexible column takes the rest, and each column's `ScrollView` owns the scrolling inside it
- **A `ScrollView` fills only when its container offers it height** — one wrapped in a content-sized `VStack` collapses the whole page along with it; the filling frame belongs on the page's content region, not on the scroll view alone
- **Layout is not unit-testable — report it as unverified** — a clean `swift build` says nothing about geometry. When a change touches page layout, state in the delivery that the layout is unverified unless it was actually seen running; never imply success from compilation alone

## References

- [CONTRIBUTING.md](CONTRIBUTING.md) — full contributor guide
- [README.md](README.md) — product overview and feature list


## Test

- **Unit tests are the primary testing method** — cover new logic with unit tests in the Swift test suite; do not verify behavior by launching the app, running scans against real files, or any other manual testing
- **Running tests requires special approval** — do not run `swift test` or launch the app or agent unless the user explicitly approves it for the current change. Approval is per-change and does not carry over; do not waste time on unapproved runs
- **No hallucination.** Never claim a change is verified, tested, or working without evidence. If a build or test was not run, say so plainly instead of implying success. Do not invent APIs, behaviors, file contents, or test output — verify against the real code, or report the unknown as unknown.
- **Verify external behavior against the real thing** — before writing a parser or an integration for an external CLI, run it and capture its actual output; an assumed output format is the same class of error as an unverified claim. When a sample cannot be produced (a machine without the tool installed, an empty result set), read the tool's own source or documentation instead of guessing.
- **Code-first delivery.** Deliver working code, not descriptions of code. Every change must follow the conventions above: Swift 6 strict concurrency, localized user-facing strings, comments that explain "why", `MackitLog` logging, and Conventional Commits messages.
- **No security risks.** No hardcoded secrets or credentials, no force-unwrapping of untrusted input, no unsafe path handling — validate paths before any delete, and never broaden a rule's scope beyond what it needs to clean.