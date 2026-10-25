import Foundation
import Testing

@testable import Mackit

/// The progress reader: which of brew's output lines it counts, which it
/// ignores, and what that does to the bar.
///
/// Every shape below comes from brew 7.x — the per-package and per-item
/// lines from its source (`upgrade.rb`, `cask/upgrade.rb`, `uninstall.rb`,
/// `cleanup.rb`), the plan headers from a real `brew upgrade --dry-run` run
/// and `brew autoremove`'s code path. An unrecognized line must change
/// nothing: brew's output is prose, and the bar must never lie about it.
struct HomebrewProgressTests {
    private func progress(
        total: Int? = nil,
        streaming lines: [String] = []
    ) -> HomebrewProgress {
        var progress = HomebrewProgress(action: .upgradeAll, total: total)
        for line in lines { progress.append(line) }
        return progress
    }

    // MARK: - Plan headers

    @Test func planHeadersStateTheTotal() {
        // The dry-run preview's own words, captured from a real run.
        #expect(HomebrewProgress.plannedCount("==> Would upgrade 10 outdated packages") == 10)
        #expect(HomebrewProgress.plannedCount("==> Upgrading 3 outdated packages") == 3)
        #expect(HomebrewProgress.plannedCount("==> Autoremoving 3 unneeded formulae:") == 3)
        #expect(HomebrewProgress.plannedCount("==> Autoremoving 1 unneeded formula:") == 1)
        #expect(HomebrewProgress.plannedCount("==> Autoremoving notanumber unneeded formulae:") == nil)
        #expect(HomebrewProgress.plannedCount("==> Downloading https://ghcr.io/v2/x") == nil)
        #expect(HomebrewProgress.plannedCount("Upgrading 3 outdated packages") == nil, "a missing headline prefix is not brew's shape")
    }

    @Test func thePlanHeaderSetsTheTotalOnlyOnce() {
        let result = progress(total: nil, streaming: [
            "==> Autoremoving 3 unneeded formulae:",
            "==> Would upgrade 9 outdated packages"
        ])
        #expect(result.total == 3, "the first total wins — later headers describe other runs")
    }

    @Test func aSeededTotalIsNotOverwritten() {
        let result = progress(total: 5, streaming: ["==> Upgrading 2 outdated packages"])
        #expect(result.total == 5, "the model's plan is the one the bar was drawn against")
    }

    // MARK: - Package steps

    @Test func packageStepsCountAndNameThePackage() {
        #expect(HomebrewProgress.upgradedPackage("==> Upgrading codex") == "codex")
        #expect(HomebrewProgress.upgradedPackage("==> Upgrading anomalyco/tap/opencode-v2") == "anomalyco/tap/opencode-v2")
        #expect(HomebrewProgress.upgradedPackage("==> Upgrading openssl@4") == "openssl@4")
    }

    @Test func lookAlikeLinesAreNotPackageSteps() {
        // A pulled-in dependency: counting it would inflate the plan the bar
        // was drawn against.
        #expect(HomebrewProgress.upgradedPackage("==> Upgrading gh dependency: openssl (3.0->4.0)") == nil)
        // The past-tense summary at the end of the run.
        #expect(HomebrewProgress.upgradedPackage("==> Upgraded 10 outdated packages") == nil)
        // The plan header itself.
        #expect(HomebrewProgress.upgradedPackage("==> Upgrading 10 outdated packages") == nil)
        // No headline prefix at all.
        #expect(HomebrewProgress.upgradedPackage("Upgrading codex") == nil)
    }

    @Test func removalLinesNameTheItem() {
        #expect(HomebrewProgress.removedItem("==> Uninstalling Cask codex") == "codex")
        #expect(HomebrewProgress.removedItem("Uninstalling /opt/homebrew/Cellar/gh/2.102.0... (1,234 files, 45.6MB)") == "gh")
        #expect(HomebrewProgress.removedItem("Uninstalling codex... (1 app, 5.2MB)") == "codex")
        #expect(HomebrewProgress.removedItem("==> Downloading https://ghcr.io/v2/x") == nil)
    }

    // MARK: - Counting

    @Test func aFullUpgradeRunCountsOneStepPerPackage() {
        let result = progress(total: 3, streaming: [
            "==> Fetching downloads for...",
            "==> Downloading https://ghcr.io/v2/homebrew/core/cairo/manifests/1.2.3",
            "==> Upgrading cairo",
            "  1.18.0 -> 1.18.2",
            "==> Pouring cairo--1.18.2.arm64_sonoma.bottle.tar.gz",
            "==> Upgrading codex",
            "==> Upgrading gh dependency: openssl (3.0->4.0)",
            "==> Upgrading gh",
            "==> Upgraded 3 outdated packages"
        ])
        #expect(result.completed == 3)
        #expect(result.fraction == 1)
        #expect(result.currentStep == "gh")
        #expect(result.log.count == 9, "every line stays in the log, counted or not")
    }

    @Test func aDependencyUpgradeDoesNotInflateTheCount() {
        let result = progress(total: 1, streaming: [
            "==> Upgrading gh dependency: openssl (3.0->4.0)",
            "==> Upgrading gh"
        ])
        #expect(result.completed == 1)
        #expect(result.fraction == 1)
    }

    @Test func cleanupCountsRemovalsWithoutNamingThem() {
        let result = progress(streaming: [
            "Removing: /opt/homebrew/Cellar/wget/1.0.0... (12 files, 400KB)",
            "Removing: /opt/homebrew/Cellar/node/22.0.0/bin/node... (1 file, 90MB)",
            "==> This operation has freed approximately 1.1 KB of disk space."
        ])
        #expect(result.completed == 2)
        #expect(result.currentStep == nil)
        #expect(result.fraction == nil, "no total was ever stated, so the bar stays indeterminate")
    }

    @Test func progressNeverExceedsItsPlan() {
        let result = progress(total: 1, streaming: [
            "==> Upgrading gh",
            "==> Upgrading wget"
        ])
        #expect(result.completed == 2, "the count stays honest")
        #expect(result.fraction == 1, "the bar clamps at full")
    }

    // MARK: - Log hygiene

    @Test func theLogKeepsOnlyTheFinalStateOfARewrittenLine() {
        // curl's download progress rewrites one line with "\r"; a terminal
        // shows only the last state.
        let result = progress(streaming: [
            "  % Total    % Received 10%\r  % Total    % Received 100%",
            "==> Upgrading codex"
        ])
        #expect(result.log.first == "  % Total    % Received 100%")
    }

    @Test func blankLinesAreDropped() {
        let result = progress(streaming: ["", "   ", "==> Upgrading codex"])
        #expect(result.log == ["==> Upgrading codex"])
    }

    @Test func theLogDropsTheOldestLinesOnceFull() {
        let lines = (1...HomebrewProgress.logLimit + 5).map { "line \($0)" }
        let result = progress(streaming: lines)
        #expect(result.log.count == HomebrewProgress.logLimit)
        #expect(result.log.first == "line 6")
        #expect(result.log.last == "line \(HomebrewProgress.logLimit + 5)")
    }

    @Test func finishingFreezesTheClockAndStaysIdempotent() {
        var result = progress(total: 2, streaming: ["==> Upgrading wget"])
        let start = result.startedAt

        result.finish(at: start.addingTimeInterval(90))
        #expect(result.finishedAt == start.addingTimeInterval(90))

        // A late line arriving after the outcome cannot restart the clock.
        result.append("==> Upgrading node")
        result.finish(at: start.addingTimeInterval(200))
        #expect(result.finishedAt == start.addingTimeInterval(90))
    }
}
