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

A change is not complete until `swift build` and `swift test` both pass.

## Code Conventions

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

## References

- [CONTRIBUTING.md](CONTRIBUTING.md) — full contributor guide
- [README.md](README.md) — product overview and feature list
