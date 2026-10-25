import Foundation

/// One search hit: a formula or cask in the local index, installed or not —
/// the install section shows both, marking what is already there.
struct HomebrewSearchResult: Equatable, Sendable, Identifiable {
    let name: String
    let kind: HomebrewPackage.Kind
    /// From `brew info --json=v2`; nil when the details call failed, which
    /// leaves the row actionable with just its name.
    let description: String?
    let latestVersion: String?
    let homepage: String?
    let license: String?
    let tap: String?
    let dependencies: [String]

    var id: String { "\(kind.rawValue)/\(name)" }
}

/// Searches Homebrew's local index for packages to install — the query path
/// behind the install section.
///
/// Names come from `brew search --formula` / `--cask`, one call per kind: the
/// combined `brew search` output separates the two groups with a blank line
/// that is absent when only one group matches, which leaves the kind
/// unparseable. One bulk `brew info --json=v2` per kind then enriches the
/// hits with description and version — best-effort, so a failed details call
/// still leaves name+kind rows the user can act on.
enum HomebrewSearch {
    /// Cap per kind. A one-letter query matches hundreds of packages, and a
    /// list nobody can scan is worse than a short one.
    static let resultLimit = 50

    /// Searches for `query`, returning the hits (empty when nothing matches).
    /// Nil only when brew itself could not be read.
    static func search(
        _ query: String,
        run: BrewCommand = HomebrewRunner.run
    ) async -> [HomebrewSearchResult]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // The two searches are independent reads over the same index; running
        // them together halves the wait the user is watching.
        async let formulaNames = run(["search", "--formula", trimmed], timeout)
        async let caskNames = run(["search", "--cask", trimmed], timeout)

        let formulae = parseNames(await formulaNames ?? "")
        let casks = parseNames(await caskNames ?? "")
        guard !formulae.isEmpty || !casks.isEmpty else { return [] }

        // Details: one bulk call per kind, over the names just found. Both
        // run together — they are independent reads over the same index.
        async let formulaDetails = details(of: formulae, kind: .formula, run: run)
        async let caskDetails = details(of: casks, kind: .cask, run: run)
        let formulaeDetails = await formulaDetails
        let casksDetails = await caskDetails

        return formulae.map { result($0, kind: .formula, details: formulaeDetails) }
            + casks.map { result($0, kind: .cask, details: casksDetails) }
    }

    /// Reads the timeout the inspector's queries use: a search evaluates the
    /// whole index for a short query and is useless long before the actions'
    /// ceiling.
    private static let timeout: Duration = .seconds(120)

    /// One bulk details call per kind, keyed by name. An absent or
    /// undecodable payload yields an empty map — the caller's rows then show
    /// names only.
    private static func details(
        of names: [String],
        kind: HomebrewPackage.Kind,
        run: BrewCommand
    ) async -> [String: BrewDetail] {
        guard !names.isEmpty else { return [:] }
        let arguments = kind == .formula
            ? ["info", "--json=v2"] + names
            : ["info", "--cask", "--json=v2"] + names
        guard let json = await run(arguments, timeout) else { return [:] }
        var byName: [String: BrewDetail] = [:]
        for detail in HomebrewInspector.parseInfoJSON(json, kind: kind) where byName[detail.name] == nil {
            byName[detail.name] = detail
        }
        return byName
    }

    private static func result(
        _ name: String,
        kind: HomebrewPackage.Kind,
        details: [String: BrewDetail]
    ) -> HomebrewSearchResult {
        let detail = details[name]
        return HomebrewSearchResult(
            name: name,
            kind: kind,
            description: detail?.description,
            latestVersion: detail?.latestVersion,
            homepage: detail?.homepage,
            license: detail?.license,
            tap: detail?.tap,
            dependencies: detail?.dependencies ?? []
        )
    }

    /// `brew search --formula/--cask <q>` prints one name per line once
    /// stdout is a pipe (the "==> Formulae" headers are TTY-only). Warnings
    /// never reach here — they go to stderr, which `run` drops — but the
    /// header guard stays so a future TTY-less format change degrades to
    /// fewer results instead of junk rows.
    static func parseNames(_ output: String) -> [String] {
        var names: [String] = []
        for line in output.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasPrefix("==>") else { continue }
            guard !names.contains(name) else { continue }
            names.append(name)
            if names.count >= resultLimit { break }
        }
        return names
    }
}
