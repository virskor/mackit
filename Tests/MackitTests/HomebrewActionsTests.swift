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

    /// Argument recorder for the plain actions' `run` seam. `@unchecked
    /// Sendable` for the same reason as `SizeProbe`.
    private final class ArgumentProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [[String]] = []

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

    // MARK: - cleanup

    @Test func cleanupMeasuresReclaimedAroundTheCommand() async {
        let probe = SizeProbe()
        // before: cellar 1000 + cache 500; after: cellar 400 + cache 0.
        probe.sequence = [1000, 500, 400, 0]

        let outcome = await HomebrewActions.cleanup(
            run: { arguments, _ in
                switch arguments {
                case ["--cellar"]: "/cellar"
                case ["--cache"]: "/cache"
                case ["cleanup", "--prune=all", "-s"]: "Removing: /cache/..."
                default: nil
                }
            },
            sizeOf: { probe.size(of: $0) }
        )

        #expect(outcome.succeeded)
        #expect(outcome.action == .cleanup)
        #expect(outcome.measure == 1100)
        #expect(probe.paths == ["/cellar", "/cache", "/cellar", "/cache"])
    }

    @Test func cleanupFailsWhenBrewIsUnavailable() async {
        let outcome = await HomebrewActions.cleanup(run: { _, _ in nil }, sizeOf: { _ in 0 })
        #expect(!outcome.succeeded)
        #expect(outcome.failure == L10n.tr("homebrew.error.brewUnavailable"))
    }

    @Test func cleanupFailsWhenTheCommandFails() async {
        let outcome = await HomebrewActions.cleanup(
            run: { arguments, _ in
                arguments == ["cleanup", "--prune=all", "-s"] ? nil : "/somewhere"
            },
            sizeOf: { _ in 0 }
        )
        #expect(!outcome.succeeded)
        #expect(outcome.failure == L10n.tr("homebrew.error.cleanupFailed"))
    }

    // MARK: - autoremove

    @Test func autoremoveParsesTheDroppedCount() async {
        let outcome = await HomebrewActions.autoremove(
            run: { _, _ in "==> Autoremoving 3 formulae: gettext, libtool, pcre2" }
        )
        #expect(outcome.succeeded)
        #expect(outcome.action == .autoremove)
        #expect(outcome.measure == 3)
    }

    @Test func autoremoveWithoutACountStillSucceeds() async {
        let outcome = await HomebrewActions.autoremove(run: { _, _ in "" })
        #expect(outcome.succeeded)
        #expect(outcome.measure == nil)
    }

    @Test func autoremoveFailsWhenTheCommandFails() async {
        let outcome = await HomebrewActions.autoremove(run: { _, _ in nil })
        #expect(!outcome.succeeded)
        #expect(outcome.failure == L10n.tr("homebrew.error.autoremoveFailed"))
    }

    @Test func parseAutoremovedCountShapes() {
        #expect(HomebrewActions.parseAutoremovedCount("==> Autoremoving 1 formula: x") == 1)
        #expect(HomebrewActions.parseAutoremovedCount("==> Autoremoving 12 formulae: a, b") == 12)
        #expect(HomebrewActions.parseAutoremovedCount("==> `brew autoremove` is a no-op") == nil)
        #expect(HomebrewActions.parseAutoremovedCount("") == nil)
        #expect(HomebrewActions.parseAutoremovedCount("Autoremoving notanumber") == nil)
    }

    // MARK: - package and service actions

    @Test func upgradeRunsThePerKindFlag() async {
        let probe = ArgumentProbe()
        let outcome = await HomebrewActions.run(.upgrade(.formula, "brotli"), run: { arguments, _ in
            probe.record(arguments)
            return "==> Upgrading brotli"
        })
        #expect(outcome.succeeded)
        #expect(outcome.action == .upgrade(.formula, "brotli"))
        #expect(outcome.measure == nil)
        #expect(probe.calls == [["upgrade", "--formula", "brotli"]])

        _ = await HomebrewActions.run(.upgrade(.cask, "codex"), run: { arguments, _ in
            probe.record(arguments)
            return "==> Upgrading codex"
        })
        #expect(probe.calls.last == ["upgrade", "--cask", "codex"])
    }

    @Test func uninstallRunsThePerKindFlag() async {
        let probe = ArgumentProbe()
        let outcome = await HomebrewActions.run(.uninstall(.cask, "codex"), run: { arguments, _ in
            probe.record(arguments)
            return "==> Uninstalling codex"
        })
        #expect(outcome.succeeded)
        #expect(probe.calls == [["uninstall", "--cask", "codex"]])
    }

    @Test func upgradeAllRunsPlainUpgrade() async {
        let probe = ArgumentProbe()
        _ = await HomebrewActions.run(.upgradeAll, run: { arguments, _ in
            probe.record(arguments)
            return "==> Upgrading 3 outdated packages"
        })
        #expect(probe.calls == [["upgrade"]])
    }

    @Test func serviceActionsRunTheServicesSubcommand() async {
        let probe = ArgumentProbe()
        let run: BrewCommand = { arguments, _ in
            probe.record(arguments)
            return "==> Successfully started `mysql`"
        }
        _ = await HomebrewActions.run(.startService("mysql"), run: run)
        _ = await HomebrewActions.run(.stopService("mysql"), run: run)
        _ = await HomebrewActions.run(.restartService("mysql"), run: run)
        #expect(probe.calls == [
            ["services", "start", "mysql"],
            ["services", "stop", "mysql"],
            ["services", "restart", "mysql"]
        ])
    }

    @Test func failedActionCarriesTheGenericMessage() async {
        let outcome = await HomebrewActions.run(.uninstall(.formula, "wget"), run: { _, _ in nil })
        #expect(!outcome.succeeded)
        #expect(outcome.failure == L10n.tr("homebrew.error.actionFailed"))
    }
}
