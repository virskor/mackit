# Contributing to Mackit

Issues and Pull Requests are welcome. This document explains how to build and test the project, and covers the coding conventions we follow.

## Requirements

- macOS 14+
- Xcode 16+ (Swift 6)

## Build & Run

```bash
git clone https://github.com/virskor/mackit.git
cd mackit

./run.sh                  # Build debug and launch (fastest iteration)
./run.sh release          # Build release and launch
./run.sh debug -n         # Build only, no launch
```

Alternatively, open `Package.swift` in Xcode and run the `Mackit` scheme. Development builds compile for the native architecture only.

## Testing

```bash
swift test
```

New features should come with tests — follow the existing organization in `Tests/MackitTests/`. Changes to user-facing strings are validated by `LocalizationTests`, which checks key completeness and placeholder consistency.

## Code Conventions

- **Swift 6 Strict Concurrency is enabled** — new code must pass concurrency checking; if an exemption is truly needed, explain why in a comment
- **Comments explain "why", not "what"**: constraints, trade-offs, and pitfalls you've hit are worth writing down; obvious logic doesn't need a comment
- **All user-facing strings go through localization**: no user-facing literals in code — use `Utilities/L10n.swift` (`L10n.tr` / `L10n.fmt` / `L10n.items`) and add strings to `Sources/Mackit/Resources/Localizable.xcstrings` for all three languages
- **Singular and plural keys (`.one` / `.other`) must use consistent placeholder layouts** — the `.one` string must also include `%lld`, changing only the noun to singular; otherwise `%@` receives an integer and the UI crashes on render
- Logging goes through `Utilities/MackitLog.swift` (`os.Logger`) — record only counts, sizes, durations, and rule IDs, never file contents
- New scan rules go in `Engine/RulesCatalog.swift`, following the organization of the existing rules

## Commits & PRs

- Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages: `feat:` / `fix:` / `docs:` / `refactor:` / `test:` / `chore:`; commit messages and PR descriptions are written in English
- Keep PRs small and focused; explain the motivation and impact, and link related issues
- Before merging, self-check: `swift build` passes, `swift test` passes, strings added in all three languages

## Security

- Private keys, certificates, and credentials (`*.p8` / `*.pem` / `*.key` / `*.p12`, etc.) **never go into the repository** — `.gitignore` already blocks them; a pre-commit hook is recommended as a safety net: `Scripts/install-git-hooks.sh` (run it once after cloning on a new machine)
- Credential management for the release pipeline is documented in [docs/RELEASE.md](docs/RELEASE.md)

## Code of Conduct

By participating in this project, you agree to abide by the [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
