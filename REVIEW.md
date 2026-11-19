# REVIEW.md

Code review rules for Mackit. The bar is industrial delivery quality: every rule in
[AGENTS.md](AGENTS.md) is binding on every change, and this file adds the review process that
verifies it. No change merges without passing both.

## Ground rules

- **Every finding cites `file:line` and quotes the actual code.** A concern that cannot be
  pointed at a real line in the diff is a question, not a finding.
- **Nothing is claimed from memory.** Before reporting broken behavior, an availability
  problem, or missing reuse, verify it: read the surrounding lines, grep for the symbol, check
  the SDK annotation. "I believe this API is newer than 14" is not a finding; the SDK header is.
- **Unverified means unverified.** If the review could not check something — build or tests not
  run, layout not seen running, external CLI output never captured — say so plainly. Never
  imply success that was not observed.
- **Judge only what is in the diff.** Do not report a problem the change neither caused nor
  should have addressed, and do not review the code around it on the change's behalf.

## Hallucinated code

A diff can hallucinate, and approving it ships the hallucination. Look for it actively:

- symbols, APIs, files, or modules that do not exist in the codebase — grep before believing
  the code compiles
- localization keys missing from `Localizable.xcstrings`, or present in only some of the eight
  languages
- comments, docs, or changelog lines describing behavior the code does not implement
- tests encoding invented expectations (e.g. an assumed output format of an external tool)
  instead of behavior captured from the real tool
- rule IDs, paths, or names that match nothing that exists

A finding on any of these is held to the same evidence bar as any other: the symbol was
searched for, the key was looked up, the expectation was traced to a captured run.

## Checklist

- [ ] `swift build` and `swift test` pass, or the gap is explicitly reported
- [ ] No redundant code: every new helper, component, constant, or rule was checked against
      existing ones first and reuses them where they fit; a second copy of logic that already
      exists is a blocker
- [ ] Visual values come from `Theme.*` — no literal colors, `Font.system(size:)`, or ad-hoc
      radii
- [ ] Every user-facing string goes through `L10n` and exists in all eight languages; plural
      families share one placeholder layout
- [ ] Views claim their container and transient states center in a frame with real height;
      layout changes are reported as unverified unless seen running
- [ ] Swift 6 strict concurrency is clean; any exemption states why in a comment
- [ ] Logging goes through `MackitLog`: counts, sizes, durations, rule IDs only, never file
      contents
- [ ] Every API above macOS 14 is `#available`-guarded and has a fallback that actually runs on
      14
- [ ] Scan-rule changes stay within the rule's scope and follow `RulesCatalog` organization
- [ ] No secrets, no force-unwrapped untrusted input, paths validated before any delete
- [ ] Comments explain why and match what the code does; the commit message follows
      Conventional Commits

## Output

Group findings by severity — **Blocker**, **Major**, **Minor**, **Nit** — each with a
`file:line`, the quoted code, what is wrong, and the concrete fix. End with one verdict:
**approved**, **approved with minor fixes**, or **changes requested**. A blocker is listed
first; a review that buries one under fifteen nits has failed regardless of its thoroughness.
