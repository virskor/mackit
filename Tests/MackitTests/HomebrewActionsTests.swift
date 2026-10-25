import Foundation
import Testing

@testable import Mackit

/// The management actions: what each runs, what it reports, and how failures
/// surface. Every subprocess and every measurement is injected, so nothing
/// here touches a real Homebrew.
struct HomebrewActionsTests {
    /// Call-counting size seam for the cleanup measurement. `@unchecked
    /// Sendable` because the closure mutates it from the action's task.
    private final class SizeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(path: String, value: Int64)] = []

        /// Sizes by call order: cellar-before, cache-before, cellar-after,
        /// cache-after — the order `cleanup` measures in.
        var sequence: [Int64] = []

        func size(of path: String) -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            let index = calls.count
            calls.append((path, sequence[index]))
            return sequence[index]
        }

        var paths: [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls.map(\.path)
        }
    }

    /// Recorder for the streaming seam: the arguments it was called with and
    /// every line it reported. `@unchecked Sendable` because the fake closure
    /// runs on the action's task.
    private final class LineProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var argumentsSeen: [[String]] = []
        private var linesSeen: [String] = []

        func record(_ arguments: [String]) {
            lock.lock()
            defer { lock.unlock() }
            argumentsSeen.append(arguments)
        }

        func recordLine(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            linesSeen.append(line)
        }

        var calls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return argumentsSeen
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return linesSeen
        }
    }

    /// The streaming seam for canned `output`: reports each line the way the
    /// real runner does and records both the call and the lines.
    private func stream(_ output: String?, into probe: LineProbe) -> BrewStreamCommand {
        { arguments, _, onLine in
            probe.record(arguments)
            guard let output else { return nil }
            for line in output.split(separator: "\n") {
                let text = String(line)
                await onLine(text)
                probe.recordLine(text)
            }
            return output
        }
    }

    // MARK: - cleanup

    @Test func cleanupMeasuresReclaimedAroundTheCommand() async {
        let probe = SizeProbe()
        // before: cellar 1000 + cache 500; after: cellar 400 + cache 0.
        probe.sequence = [1000, 500, 400, 0]
        let lines = LineProbe()

        let outcome = await HomebrewActions.cleanup(
            run: { arguments, _ in
                switch arguments {
                case ["--cellar"]: "/cellar"
                case ["--cache"]: "/cache"
                default: nil
                }
            },
            stream: stream("==> This operation has freed approximately 1.1 KB of disk space.", into: lines),
            sizeOf: { probe.size(of: $0) }
        )

        #expect(outcome.succeeded)
        #expect(outcome.action == .cleanup)
        #expect(outcome.measure == 1100)
        #expect(probe.paths == ["/cellar", "/cache", "/cellar", "/cache"])
        #expect(lines.calls == [["cleanup", "--prune=all", "-s"]])
        #expect(lines.lines == ["==> This operation has freed approximately 1.1 KB of disk space."])
    }

    @Test func cleanupFailsWhenBrewIsUnavailable() async {
        let outcome = await HomebrewActions.cleanup(
            run: { _, _ in nil },
            stream: stream("", into: LineProbe()),
            sizeOf: { _ in 0 }
        )
        #expect(!outcome.succeeded)
        #expect(outcome.failure == L10n.tr("homebrew.error.brewUnavailable"))
    }

    @Test func cleanupFailsWhenTheCommandFails() async {
        let outcome = await HomebrewActions.cleanup(
            run: { arguments, _ in
                arguments == ["cleanup", "--prune=all", "-s"] ? nil : "/somewhere"
            },
            stream: stream(nil, into: LineProbe()),
            sizeOf: { _ in 0 }
        )
        #expect(!outcome.succeeded)
        #expect(outcome.failure == L10n.tr("homebrew.error.cleanupFailed"))
    }

    // MARK: - autoremove

    @Test func autoremoveParsesTheDroppedCount() async {
        // The shape brew 7.x actually prints: the headline states the count,
        // the names follow on their own lines.
        let outcome = await HomebrewActions.autoremove(
            stream: stream("==> Autoremoving 3 unneeded formulae:\ngettext\nlibtool\npcre2", into: LineProbe())
        )
        #expect(outcome.succeeded)
        #expect(outcome.action == .autoremove)
        #expect(outcome.measure == 3)
    }

    @Test func autoremoveWithoutACountStillSucceeds() async {
        let outcome = await HomebrewActions.autoremove(stream: stream("", into: LineProbe()))
        #expect(outcome.succeeded)
        #expect(outcome.measure == nil)
    }

    @Test func autoremoveFailsWhenTheCommandFails() async {
        let outcome = await HomebrewActions.autoremove(stream: stream(nil, into: LineProbe()))
        #expect(!outcome.succeeded)
        #expect(outcome.failure == L10n.tr("homebrew.error.autoremoveFailed"))
    }

    @Test func parseAutoremovedCountShapes() {
        #expect(HomebrewActions.parseAutoremovedCount("==> Autoremoving 1 unneeded formula:") == 1)
        #expect(HomebrewActions.parseAutoremovedCount("==> Autoremoving 12 unneeded formulae:") == 12)
        #expect(HomebrewActions.parseAutoremovedCount("==> Autoremoving notanumber unneeded formulae:") == nil)
        #expect(HomebrewActions.parseAutoremovedCount("==> `brew autoremove` is a no-op") == nil)
        #expect(HomebrewActions.parseAutoremovedCount("") == nil)
    }

    // MARK: - package and service actions

    @Test func upgradeRunsThePerKindFlag() async {
        let lines = LineProbe()
        let stream = stream("==> Upgrading brotli", into: lines)

        let outcome = await HomebrewActions.run(.upgrade(.formula, "brotli"), stream: stream)
        #expect(outcome.succeeded)
        #expect(outcome.action == .upgrade(.formula, "brotli"))
        #expect(outcome.measure == nil)
        #expect(lines.calls == [["upgrade", "--formula", "brotli"]])

        _ = await HomebrewActions.run(.upgrade(.cask, "codex"), stream: stream)
        #expect(lines.calls.last == ["upgrade", "--cask", "codex"])
    }

    @Test func uninstallRunsThePerKindFlag() async {
        let lines = LineProbe()
        let outcome = await HomebrewActions.run(
            .uninstall(.cask, "codex"),
            stream: stream("==> Uninstalling Cask codex", into: lines)
        )
        #expect(outcome.succeeded)
        #expect(lines.calls == [["uninstall", "--cask", "codex"]])
    }

    @Test func installRunsWithoutAKindFlag() async {
        // brew resolves formulae and casks from the name itself, the same way
        // the command line does.
        let lines = LineProbe()
        let outcome = await HomebrewActions.run(
            .install("meilisearch"),
            stream: stream("==> Pouring meilisearch--1.55.0", into: lines)
        )
        #expect(outcome.succeeded)
        #expect(outcome.action == .install("meilisearch"))
        #expect(lines.calls == [["install", "meilisearch"]])
        #expect(outcome.message == L10n.fmt("homebrew.result.installed", "meilisearch"))
    }

    @Test func installStreamsItsOutputForTheProgressPill() async {
        let lines = LineProbe()
        _ = await HomebrewActions.run(
            .install("meilisearch"),
            stream: stream("""
            ==> Downloading https://ghcr.io/v2/homebrew/core/meilisearch/manifests/1.55.0
            ==> Fetching downloads for: meilisearch
            ==> Pouring meilisearch--1.55.0.arm64_sonoma.bottle.tar.gz
            🍺  /opt/homebrew/Cellar/meilisearch/1.55.0: 1,234 files, 89MB
            """, into: lines)
        )
        #expect(lines.lines.count == 4, "every brew line reaches the log")
        #expect(lines.lines.last?.hasPrefix("🍺") == true)
    }

    @Test func upgradeAllRunsPlainUpgrade() async {
        let lines = LineProbe()
        _ = await HomebrewActions.run(.upgradeAll, stream: stream("==> Upgraded 3 outdated packages", into: lines))
        #expect(lines.calls == [["upgrade"]])
    }

    @Test func serviceActionsRunTheServicesSubcommand() async {
        let lines = LineProbe()
        let stream = stream("==> Successfully started `mysql`", into: lines)
        _ = await HomebrewActions.run(.startService("mysql"), stream: stream)
        _ = await HomebrewActions.run(.stopService("mysql"), stream: stream)
        _ = await HomebrewActions.run(.restartService("mysql"), stream: stream)
        #expect(lines.calls == [
            ["services", "start", "mysql"],
            ["services", "stop", "mysql"],
            ["services", "restart", "mysql"]
        ])
    }

    @Test func failedActionCarriesTheGenericMessage() async {
        let outcome = await HomebrewActions.run(.uninstall(.formula, "wget"), stream: stream(nil, into: LineProbe()))
        #expect(!outcome.succeeded)
        #expect(outcome.failure == L10n.tr("homebrew.error.actionFailed"))
    }

    // MARK: - outcome messages

    @Test func outcomeMessagesCarryTheirMeasures() {
        let cleaned = HomebrewOutcome(action: .cleanup, measure: 1_200_000_000, failure: nil)
        #expect(cleaned.message == L10n.fmt("homebrew.result.cleaned", Formatters.bytes(1_200_000_000)))

        let nothing = HomebrewOutcome(action: .cleanup, measure: 0, failure: nil)
        #expect(nothing.message == L10n.tr("homebrew.result.cleanedNone"))

        let one = HomebrewOutcome(action: .autoremove, measure: 1, failure: nil)
        #expect(one.message == L10n.fmt("homebrew.result.autoremoved.one", 1))

        let many = HomebrewOutcome(action: .autoremove, measure: 4, failure: nil)
        #expect(many.message == L10n.fmt("homebrew.result.autoremoved.other", 4))

        let upgraded = HomebrewOutcome(action: .upgrade(.cask, "codex"), measure: nil, failure: nil)
        #expect(upgraded.message == L10n.fmt("homebrew.result.upgraded", "codex"))

        let failed = HomebrewOutcome(action: .uninstall(.formula, "wget"), measure: nil, failure: "boom")
        #expect(failed.message == L10n.fmt("homebrew.result.failed", "boom"))
    }

    @Test func runningTitlesNameEachAction() {
        #expect(HomebrewAction.cleanup.runningTitle == L10n.tr("homebrew.running.cleanup"))
        #expect(HomebrewAction.upgradeAll.runningTitle == L10n.tr("homebrew.running.upgradeAll"))
        #expect(HomebrewAction.upgrade(.cask, "codex").runningTitle == L10n.tr("homebrew.running.upgrade"))
        #expect(HomebrewAction.install("meilisearch").runningTitle == L10n.tr("homebrew.running.install"))
        #expect(HomebrewAction.startService("mysql").runningTitle == L10n.tr("homebrew.running.service"))
    }
}
