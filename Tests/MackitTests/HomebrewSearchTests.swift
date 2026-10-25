import Foundation
import Testing

@testable import Mackit

/// The install section's query path: what `brew search` output parses into,
/// and how the details calls enrich the hits.
///
/// The fixtures are trimmed real payloads from brew 7.x — the name lists
/// from `brew search --formula/--cask meilisearch`, the details from
/// `brew info --json=v2 meilisearch` and `brew info --cask --json=v2
/// firefox`. Every subprocess is injected.
struct HomebrewSearchTests {
    /// The search seam over canned answers per arguments, recording the
    /// calls so a test can pin which brew commands ran and in what shape.
    private final class RunProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [[String]] = []
        /// Canned answers per arguments; file-internal so the test's `run`
        /// helper can read it.
        var answers: [[String]: String?] = [:]

        func answer(_ arguments: [String], _ output: String?) {
            lock.lock()
            defer { lock.unlock() }
            answers[arguments] = output
        }

        func record(_ arguments: [String]) {
            lock.lock()
            defer { lock.unlock() }
            seen.append(arguments)
        }

        var calls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }

    private func run(_ probe: RunProbe) -> BrewCommand {
        { arguments, _ in
            probe.record(arguments)
            return probe.answers[arguments] ?? nil
        }
    }

    /// `brew info --json=v2 meilisearch`, trimmed to the fields the page
    /// reads.
    private static let formulaInfo = """
    {"formulae":[{"name":"meilisearch","full_name":"meilisearch","desc":"Ultra relevant, instant and typo-tolerant full-text search API","homepage":"https://docs.meilisearch.com/","versions":{"stable":"1.55.0"},"dependencies":[]}]}
    """

    /// `brew info --cask --json=v2 mediaelch`, trimmed the same way. Note the
    /// absent `installed` field — the cask is not installed, which is the
    /// normal case for a search hit.
    private static let caskInfo = """
    {"casks":[{"token":"mediaelch","name":["MediaElch"],"desc":"Media Manager for Kodi","homepage":"https://kvibes.de/en/mediaelch/","version":"2.12.0,2024-10-13,80324653"}]}
    """

    // MARK: - Name parsing

    @Test func searchNamesParseOnePerLine() {
        #expect(HomebrewSearch.parseNames("meilisearch\nmediaelch\n") == ["meilisearch", "mediaelch"])
        #expect(HomebrewSearch.parseNames("  node  \n\n") == ["node"])
    }

    @Test func searchNamesDropHeadlinesAndDuplicates() {
        // Non-TTY brew prints no headers, but a future format change must
        // degrade to fewer results instead of junk rows.
        #expect(HomebrewSearch.parseNames("==> Formulae\nnode\nnode\n") == ["node"])
        #expect(HomebrewSearch.parseNames("").isEmpty)
    }

    @Test func searchNamesCapAtTheLimit() {
        let many = (1...HomebrewSearch.resultLimit + 20).map { "pkg\($0)" }.joined(separator: "\n")
        #expect(HomebrewSearch.parseNames(many).count == HomebrewSearch.resultLimit)
    }

    // MARK: - The search flow

    @Test func searchSplitsByKindAndEnrichesWithDetails() async throws {
        let probe = RunProbe()
        probe.answer(["search", "--formula", "meilisearch"], "meilisearch\n")
        probe.answer(["search", "--cask", "meilisearch"], "mediaelch\n")
        probe.answer(["info", "--json=v2", "meilisearch"], Self.formulaInfo)
        probe.answer(["info", "--cask", "--json=v2", "mediaelch"], Self.caskInfo)

        let results = await HomebrewSearch.search("meilisearch", run: run(probe))

        #expect(results?.count == 2)
        let formula = try #require(results?.first { $0.kind == .formula })
        #expect(formula.name == "meilisearch")
        #expect(formula.description == "Ultra relevant, instant and typo-tolerant full-text search API")
        #expect(formula.latestVersion == "1.55.0")
        #expect(formula.homepage == "https://docs.meilisearch.com/")

        let cask = try #require(results?.first { $0.kind == .cask })
        #expect(cask.name == "mediaelch")
        #expect(cask.description == "Media Manager for Kodi")
        #expect(cask.latestVersion == "2.12.0,2024-10-13,80324653")
    }

    @Test func searchReadsTheRightArguments() async {
        let probe = RunProbe()
        probe.answer(["search", "--formula", "codex"], "codex\n")
        probe.answer(["search", "--cask", "codex"], "codex-app\n")
        probe.answer(["info", "--json=v2", "codex"], "{\"formulae\":[]}")
        probe.answer(["info", "--cask", "--json=v2", "codex-app"], "{\"casks\":[]}")

        _ = await HomebrewSearch.search("codex", run: run(probe))

        #expect(probe.calls == [
            ["search", "--formula", "codex"],
            ["search", "--cask", "codex"],
            ["info", "--json=v2", "codex"],
            ["info", "--cask", "--json=v2", "codex-app"]
        ])
    }

    @Test func noMatchesAndAnUnreadableBrewBothReadAsTheEmptySet() async {
        // `brew search` exits 1 with empty stdout when nothing matches
        // (verified on brew 7.x), so a nil from the runner cannot mean
        // "failed" — it is also what a brew that broke mid-session looks
        // like. Both read as "no results"; the probe leaves every call
        // unanswered, which is exactly that nil shape.
        let probe = RunProbe()

        let results = await HomebrewSearch.search("zzzznotfound", run: run(probe))

        #expect(results?.isEmpty == true)
        // No names means no details calls either.
        #expect(probe.calls.count == 2)
    }

    @Test func aFailedKindDegradesToTheOtherKindsHits() async throws {
        // The formula search could not be read, but the cask side answered:
        // the section shows what it could read rather than failing wholesale.
        let probe = RunProbe()
        probe.answer(["search", "--cask", "codex"], "codex\n")
        probe.answer(["info", "--cask", "--json=v2", "codex"], "{\"casks\":[]}")

        let results = await HomebrewSearch.search("codex", run: run(probe))

        #expect(results?.count == 1)
        let hit = try #require(results?.first)
        #expect(hit.kind == .cask)
        #expect(hit.description == nil)
    }

    @Test func searchSurvivesAFailedDetailsCall() async throws {
        // Names alone are still actionable; the rows just show no
        // description.
        let probe = RunProbe()
        probe.answer(["search", "--formula", "meilisearch"], "meilisearch\n")
        probe.answer(["search", "--cask", "meilisearch"], "")
        // No answer for the info call — it returns nil.

        let results = await HomebrewSearch.search("meilisearch", run: run(probe))
        let formula = try #require(results?.first)
        #expect(formula.name == "meilisearch")
        #expect(formula.description == nil)
        #expect(formula.latestVersion == nil)
    }

    @Test func aBlankQuerySearchesNothing() async {
        let probe = RunProbe()
        #expect(await HomebrewSearch.search("   ", run: run(probe))?.isEmpty == true)
        #expect(probe.calls.isEmpty)
    }
}
