import Foundation
import Testing

@testable import Mackit

/// The model's contracts: lazy per-section loading, session-lifetime
/// snapshots, action bookkeeping, and the derived data the panes read.
///
/// Every query and action is injected, so nothing here touches a real
/// Homebrew installation.
@MainActor
struct HomebrewModelTests {
    /// Mutable counters the injected closures bump; `@unchecked Sendable`
    /// because the model calls the closures from its own tasks.
    private final class Counters: @unchecked Sendable {
        var inspect = 0
        var services = 0
        var diagnostics = 0
        var config = 0
        var actions: [HomebrewAction] = []
        /// Lines the action streamed, in arrival order.
        var streamed: [String] = []
        /// Queries the search seam saw, in order.
        var searches: [String] = []
    }

    private func makeResult(
        _ name: String,
        kind: HomebrewPackage.Kind = .formula,
        description: String? = nil
    ) -> HomebrewSearchResult {
        HomebrewSearchResult(
            name: name,
            kind: kind,
            description: description,
            latestVersion: "1.0.0",
            homepage: nil,
            license: nil,
            tap: nil,
            dependencies: []
        )
    }

    private func makePackage(
        _ name: String,
        kind: HomebrewPackage.Kind = .formula,
        outdated: Bool = false,
        dependencies: [String] = [],
        /// The on-request flag; nil is what degraded mode produces for every
        /// package.
        onRequest: Bool? = true
    ) -> HomebrewPackage {
        HomebrewPackage(
            name: name,
            displayName: name,
            kind: kind,
            installedVersion: "1.0.0",
            latestVersion: outdated ? "2.0.0" : nil,
            isOutdated: outdated,
            description: "\(name) description",
            homepage: "https://example.com/\(name)",
            license: "MIT",
            tap: "homebrew/core",
            dependencies: dependencies,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            installedOnRequest: onRequest,
            pouredFromBottle: true,
            pinned: false,
            size: 1024
        )
    }

    private func makeSnapshot(
        formulae: [HomebrewPackage] = [],
        casks: [HomebrewPackage] = [],
        detailsAvailable: Bool = true
    ) -> HomebrewSnapshot {
        HomebrewSnapshot(
            brewPath: "/fake/brew",
            version: "4.4.15",
            prefix: "/opt/homebrew",
            cachePath: "/fake/cache",
            cacheSize: 2048,
            cellarPath: "/fake/cellar",
            cellarSize: 4096,
            formulae: formulae,
            casks: casks,
            detailsAvailable: detailsAvailable
        )
    }

    private func makeModel(
        counters: Counters = Counters(),
        snapshot: HomebrewSnapshot? = nil,
        /// Replaces the fixed snapshot answer on every inspect; a test whose
        /// brew "installs" mid-run injects a closure that changes its mind
        /// between loads.
        inspectOverride: (@MainActor () -> HomebrewSnapshot?)? = nil,
        services: [HomebrewService]? = [],
        outcome: HomebrewOutcome = HomebrewOutcome(action: .cleanup, measure: 512, failure: nil),
        /// Lines the fake action streams while it "runs"; empty means the
        /// action prints nothing.
        streaming: [String] = [],
        /// What the fake search seam returns for any query; nil means "brew
        /// could not be read".
        searchResults: [HomebrewSearchResult]? = nil,
        /// How long the finished action's pill stays up. Long by default so
        /// the "still up after the action" assertions cannot flake; the dwell
        /// tests inject a short one.
        pillDwell: Duration = .seconds(30)
    ) -> HomebrewModel {
        HomebrewModel(
            inspect: {
                counters.inspect += 1
                return inspectOverride?() ?? snapshot
            },
            loadServices: {
                counters.services += 1
                return services
            },
            loadDiagnostics: {
                counters.diagnostics += 1
                return "doctor output"
            },
            loadConfig: {
                counters.config += 1
                return [HomebrewConfigEntry(key: "HOMEBREW_PREFIX", value: "/opt/homebrew")]
            },
            perform: { action, onLine in
                counters.actions.append(action)
                for line in streaming {
                    onLine(line)
                    counters.streamed.append(line)
                }
                return outcome
            },
            runSearch: { query in
                counters.searches.append(query)
                return searchResults
            },
            pillDwell: pillDwell
        )
    }

    // MARK: - Loading

    @Test func activateLoadsOnceAndKeepsTheSnapshot() async {
        let counters = Counters()
        let model = makeModel(counters: counters, snapshot: makeSnapshot(formulae: [makePackage("wget")]))

        model.activate()
        await model.waitUntilSettled()
        #expect(model.snapshot != nil)
        #expect(counters.inspect == 1)

        // Coming back must not re-query — the snapshot belongs to the session.
        model.activate()
        #expect(counters.inspect == 1)
    }

    @Test func missingHomebrewSetsTheNotInstalledFlag() async {
        let model = makeModel(snapshot: nil)
        model.activate()
        await model.waitUntilSettled()
        #expect(model.isNotInstalled)
        #expect(model.snapshot == nil)
    }

    /// The install guide's recheck: the answer flips between two loads the
    /// way a real machine does when the user installs Homebrew in Terminal
    /// and presses the page's refresh. A box rather than a captured var —
    /// the closure outlives the mutation, which strict concurrency flags.
    @Test func reloadAfterInstallingHomebrewClearsTheNotInstalledFlag() async {
        let counters = Counters()
        final class Answer: @unchecked Sendable { var installed = false }
        let answer = Answer()
        let model = makeModel(
            counters: counters,
            inspectOverride: { answer.installed ? makeSnapshot(formulae: [makePackage("wget")]) : nil }
        )

        model.activate()
        await model.waitUntilSettled()
        #expect(model.isNotInstalled)
        #expect(model.snapshot == nil)

        answer.installed = true
        model.reload()
        await model.waitUntilSettled()
        #expect(!model.isNotInstalled)
        #expect(model.snapshot?.allPackages.first?.name == "wget")
        #expect(counters.inspect == 2)
    }

    @Test func reloadReplacesAnInFlightLoad() async {
        let counters = Counters()
        let model = makeModel(counters: counters, snapshot: makeSnapshot())
        model.reload()
        model.reload()
        await model.waitUntilSettled()
        #expect(counters.inspect == 2)
        #expect(!model.isLoading)
    }

    // MARK: - Sections

    @Test func sectionsLoadTheirOwnDataOnFirstVisit() async {
        let counters = Counters()
        let model = makeModel(counters: counters, snapshot: makeSnapshot())

        // Entering the tool loads only the installed list.
        model.activate()
        await model.waitUntilSettled()
        #expect(counters.services == 0)
        #expect(counters.diagnostics == 0)
        #expect(counters.config == 0)

        model.showSection(.services)
        await model.waitUntilSettled()
        #expect(counters.services == 1)
        #expect(model.services != nil)
        // A second visit reuses the loaded data.
        model.showSection(.installed)
        model.showSection(.services)
        #expect(counters.services == 1)

        model.showSection(.diagnostics)
        await model.waitUntilSettled()
        #expect(counters.diagnostics == 1)
        #expect(model.diagnostics == "doctor output")

        model.showSection(.config)
        await model.waitUntilSettled()
        #expect(counters.config == 1)
        #expect(model.config?.first?.key == "HOMEBREW_PREFIX")
    }

    @Test func failedServicesLoadIsDistinguishableFromEmpty() async {
        let model = makeModel(services: nil)
        model.showSection(.services)
        await model.waitUntilSettled()
        #expect(model.servicesFailed)
        #expect(model.services?.isEmpty == true)
    }

    // MARK: - Actions

    @Test func packageActionReloadsTheInstalledList() async {
        let counters = Counters()
        let model = makeModel(counters: counters, snapshot: makeSnapshot())
        model.activate()
        await model.waitUntilSettled()
        #expect(counters.inspect == 1)

        model.run(.upgrade(.formula, "wget"))
        await model.waitUntilSettled()

        #expect(counters.actions == [.upgrade(.formula, "wget")])
        #expect(counters.inspect == 2, "a successful upgrade re-queries the list")
        #expect(model.outcome?.measure == 512)
        #expect(model.runningAction == nil)
    }

    @Test func serviceActionReloadsTheServices() async {
        let counters = Counters()
        let model = makeModel(counters: counters, snapshot: makeSnapshot())
        model.showSection(.services)
        await model.waitUntilSettled()
        #expect(counters.services == 1)

        model.run(.stopService("mysql"))
        await model.waitUntilSettled()

        #expect(counters.actions == [.stopService("mysql")])
        #expect(counters.services == 2, "stopping a service re-queries the list")
        #expect(counters.inspect == 0, "a service action does not touch the package list")
    }

    @Test func failedActionDoesNotReload() async {
        let counters = Counters()
        let model = makeModel(
            counters: counters,
            snapshot: makeSnapshot(),
            outcome: HomebrewOutcome(action: .cleanup, measure: nil, failure: "boom")
        )
        model.activate()
        await model.waitUntilSettled()

        model.run(.cleanup)
        await model.waitUntilSettled()

        #expect(counters.inspect == 1, "a failed action changes nothing")
        #expect(model.outcome?.failure == "boom")
    }

    @Test func aSecondActionIsIgnoredWhileOneRuns() async {
        let counters = Counters()
        let model = makeModel(counters: counters, snapshot: makeSnapshot())
        model.run(.cleanup)
        model.run(.autoremove)
        await model.waitUntilSettled()
        #expect(counters.actions == [.cleanup])
    }

    // MARK: - Progress

    @Test func progressCountsBrewsPackageSteps() async {
        let counters = Counters()
        let model = makeModel(
            counters: counters,
            snapshot: makeSnapshot(formulae: [
                makePackage("wget", outdated: true),
                makePackage("node", outdated: true)
            ]),
            outcome: HomebrewOutcome(action: .upgradeAll, measure: nil, failure: nil),
            // brew's real per-package lines, in the order it prints them.
            streaming: ["==> Upgrading wget", "  1.0.0 -> 2.0.0", "==> Upgrading node", "==> Upgraded 2 outdated packages"]
        )
        model.activate()
        await model.waitUntilSettled()

        model.run(.upgradeAll)
        #expect(model.progress?.total == 2, "the plan size comes from the outdated list, not from brew")

        await model.waitUntilSettled()

        #expect(model.progress?.completed == 2)
        #expect(model.progress?.currentStep == "node")
        #expect(model.progress?.fraction == 1)
        #expect(model.progress?.finishedAt != nil, "the elapsed readout freezes at the finish")
        // HomebrewProgress normalizes every line it folds in, so the log
        // holds brew's lines whitespace-trimmed.
        #expect(model.progress?.log == [
            "==> Upgrading wget",
            "1.0.0 -> 2.0.0",
            "==> Upgrading node",
            "==> Upgraded 2 outdated packages"
        ])
        #expect(counters.streamed.count == 4, "every line reached the sink")
    }

    @Test func aSinglePackageActionPlansOneStep() async {
        let model = makeModel(snapshot: makeSnapshot())
        model.run(.upgrade(.formula, "wget"))
        #expect(model.progress?.total == 1)
        await model.waitUntilSettled()
    }

    @Test func indeterminateActionsCountStepsWithoutATotal() async {
        let model = makeModel(
            snapshot: makeSnapshot(),
            outcome: HomebrewOutcome(action: .cleanup, measure: 512, failure: nil),
            streaming: [
                "Removing: /opt/homebrew/Cellar/wget/1.0.0... (12 files, 400KB)",
                "Removing: /opt/homebrew/Cellar/node/22.0.0... (3,000 files, 90MB)"
            ]
        )

        model.run(.cleanup)
        await model.waitUntilSettled()

        #expect(model.progress?.total == nil, "cleanup never states how many paths it will remove")
        #expect(model.progress?.fraction == nil)
        #expect(model.progress?.completed == 2)
        #expect(model.progress?.currentStep == nil, "a cleanup path names no package")
    }

    @Test func autoremoveReadsItsPlanSizeFromBrewsHeader() async {
        let model = makeModel(
            snapshot: makeSnapshot(),
            outcome: HomebrewOutcome(action: .autoremove, measure: 3, failure: nil),
            streaming: [
                "==> Autoremoving 3 unneeded formulae:",
                "gettext",
                "libtool",
                "pcre2",
                "Uninstalling /opt/homebrew/Cellar/gettext/0.22.5... (213 files, 3.5MB)",
                "Uninstalling /opt/homebrew/Cellar/libtool/2.5.4... (77 files, 1.6MB)",
                "Uninstalling /opt/homebrew/Cellar/pcre2/10.44... (95 files, 6.4MB)"
            ]
        )

        model.run(.autoremove)
        await model.waitUntilSettled()

        #expect(model.progress?.total == 3, "the header is the only total brew states up front")
        #expect(model.progress?.completed == 3)
        #expect(model.progress?.currentStep == "pcre2")
        #expect(model.progress?.fraction == 1)
    }

    @Test func progressSurvivesTheActionSoTheLogStaysReachable() async {
        let model = makeModel(snapshot: makeSnapshot(), streaming: ["==> Upgrading wget"])
        model.run(.upgrade(.formula, "wget"))
        await model.waitUntilSettled()

        #expect(model.runningAction == nil)
        #expect(model.outcome != nil)
        #expect(model.progress?.log == ["==> Upgrading wget"])
    }

    // MARK: - Status pill

    @Test func thePillIsUpTheMomentAnActionStarts() {
        // The regression this pins: the pill used to be raised by the view
        // off `runningAction`'s change notification, which SwiftUI coalesces
        // away when the action finishes before the next render pass — the
        // pill then never appeared at all. The model now raises it itself, on
        // the same turn the action starts.
        let model = makeModel(snapshot: makeSnapshot())

        model.run(.upgrade(.formula, "wget"))

        #expect(model.showsStatusPill)
        #expect(model.progress != nil)
    }

    @Test func aFastActionStillShowsThePill() async {
        // The injected action completes without suspending on real I/O, the
        // same shape as a brew invocation that fails or finishes instantly.
        let model = makeModel(snapshot: makeSnapshot())
        model.run(.upgrade(.formula, "wget"))
        await model.waitUntilSettled()

        #expect(model.showsStatusPill, "a finished action keeps its pill up for the dwell")
        #expect(model.outcome != nil)
    }

    @Test func thePillDropsAfterTheDwell() async {
        // The dwell must still be pending when the settle loop returns; a
        // 20 ms one can expire first and the first expectation flakes.
        let model = makeModel(snapshot: makeSnapshot(), pillDwell: .seconds(1))
        model.run(.cleanup)
        await model.waitUntilSettled()
        #expect(model.showsStatusPill)

        try? await Task.sleep(for: .milliseconds(1200))

        #expect(!model.showsStatusPill)
    }

    @Test func anOpenLogPinsThePillPastTheDwell() async {
        // Same dwell-margin reasoning as thePillDropsAfterTheDwell: opening
        // the log must cancel a dismiss that is still armed, which a 20 ms
        // dwell cannot guarantee.
        let model = makeModel(snapshot: makeSnapshot(), pillDwell: .seconds(1))
        model.run(.cleanup)
        await model.waitUntilSettled()

        model.setActionLogVisible(true)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.showsStatusPill, "the popover is anchored to the pill; it must not vanish mid-read")

        model.setActionLogVisible(false)
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(!model.showsStatusPill, "closing the log re-arms the dwell")
    }

    @Test func aSecondActionRaisesThePillAgain() async {
        let model = makeModel(snapshot: makeSnapshot(), pillDwell: .milliseconds(20))
        model.run(.cleanup)
        await model.waitUntilSettled()
        try? await Task.sleep(for: .milliseconds(120))
        #expect(!model.showsStatusPill)

        model.run(.upgrade(.formula, "wget"))

        #expect(model.showsStatusPill)
        #expect(model.showsActionLog == false)
        await model.waitUntilSettled()
    }

    @Test func anIgnoredSecondActionLeavesThePillAlone() async {
        // A second action is refused while one runs; it must not disturb the
        // running action's pill.
        let model = makeModel(snapshot: makeSnapshot(), streaming: ["==> Upgrading wget"])
        model.run(.upgradeAll)
        model.run(.autoremove)
        await model.waitUntilSettled()

        #expect(model.showsStatusPill)
    }

    // MARK: - Install search

    @Test func searchReportsItsHitsAfterTheDebounce() async {
        let counters = Counters()
        let model = makeModel(
            counters: counters,
            snapshot: makeSnapshot(formulae: [makePackage("wget")]),
            searchResults: [makeResult("meilisearch", description: "Full-text search API")]
        )

        model.updateSearchQuery("meili")
        // Nothing before the debounce lands: a keystroke a second apart must
        // not start a brew search per character.
        #expect(model.searchResults == nil)
        #expect(counters.searches.isEmpty)

        await model.waitUntilSettled()

        #expect(counters.searches == ["meili"])
        #expect(model.searchQuery == "meili")
        #expect(model.searchResults?.first?.description == "Full-text search API")
        #expect(model.isSearching == false)
        #expect(model.searchFailed == false)
    }

    @Test func clearingTheQueryDropsTheResults() async {
        let model = makeModel(searchResults: [makeResult("meilisearch")])
        model.updateSearchQuery("meili")
        await model.waitUntilSettled()
        #expect(model.searchResults?.isEmpty == false)

        model.updateSearchQuery("")
        await model.waitUntilSettled()

        #expect(model.searchResults == nil)
        #expect(model.searchFailed == false)
        #expect(model.searchQuery == "")
    }

    @Test func aFailedSearchIsDistinctFromNoMatches() async {
        let failure = makeModel(searchResults: nil)
        failure.updateSearchQuery("meili")
        await failure.waitUntilSettled()
        #expect(failure.searchFailed)
        #expect(failure.searchResults?.isEmpty == true)

        let none = makeModel(searchResults: [])
        none.updateSearchQuery("meili")
        await none.waitUntilSettled()
        #expect(!none.searchFailed, "an empty result set is a real answer")
        #expect(none.searchResults?.isEmpty == true)
    }

    @Test func installedHitsAreMarked() async {
        let model = makeModel(snapshot: makeSnapshot(formulae: [makePackage("wget")]))
        model.activate()
        await model.waitUntilSettled()
        #expect(model.isInstalled(makeResult("wget")))
        #expect(!model.isInstalled(makeResult("node")))
        #expect(!model.isInstalled(makeResult("wget", kind: .cask)),
                "a cask sharing a formula's name is still its own package")
    }

    @Test func installReloadsTheInstalledList() async {
        let counters = Counters()
        let model = makeModel(counters: counters, snapshot: makeSnapshot())
        model.activate()
        await model.waitUntilSettled()

        model.run(.install("meilisearch"))
        await model.waitUntilSettled()

        #expect(counters.actions == [.install("meilisearch")])
        #expect(counters.inspect == 2, "a successful install re-queries the list")
        #expect(model.outcome?.succeeded == true)
    }

    @Test func anInstallIsIndeterminateWhileItRuns() async {
        // brew prints no per-package lines for an install, so the bar stays
        // indeterminate rather than sitting at zero.
        let model = makeModel(snapshot: makeSnapshot())
        model.run(.install("meilisearch"))
        #expect(model.progress?.total == nil)
        #expect(model.progress?.fraction == nil)
        await model.waitUntilSettled()
    }

    // MARK: - Uninstall confirmation

    @Test func uninstallGoesThroughConfirmation() async {
        let counters = Counters()
        let model = makeModel(counters: counters, snapshot: makeSnapshot())
        let package = makePackage("wget")

        model.requestUninstall(package)
        #expect(model.pendingUninstall?.name == "wget")

        // Cancelling leaves no trace and runs nothing.
        model.cancelUninstall()
        #expect(model.pendingUninstall == nil)
        #expect(counters.actions.isEmpty)

        model.requestUninstall(package)
        model.confirmUninstall()
        await model.waitUntilSettled()
        #expect(counters.actions == [.uninstall(.formula, "wget")])
        #expect(model.pendingUninstall == nil, "confirming clears the pending state")
    }

    @Test func selectingAnotherPackageClearsAPendingConfirmation() {
        let model = makeModel(snapshot: makeSnapshot())
        let wget = makePackage("wget")
        let node = makePackage("node")
        model.requestUninstall(wget)
        model.selectPackage(node)
        #expect(model.pendingUninstall == nil)

        // Re-selecting the same package keeps the confirmation alive.
        model.requestUninstall(wget)
        model.selectPackage(wget)
        #expect(model.pendingUninstall?.name == "wget")
    }

    // MARK: - Derived data

    @Test func packagesPerSectionAndFiltering() async {
        let model = makeModel(snapshot: makeSnapshot(
            formulae: [makePackage("wget", outdated: true), makePackage("node")],
            casks: [makePackage("codex", kind: .cask, outdated: true)]
        ))
        model.activate()
        await model.waitUntilSettled()

        #expect(model.packages(for: .installed).count == 3)
        #expect(model.packages(for: .upgrade).count == 2)
        #expect(model.packages(for: .services).isEmpty)

        let installed = model.packages(for: .installed)
        #expect(model.filtered(installed, kind: .all, dependencies: .all, by: "WGET").map(\.name) == ["wget"])
        #expect(model.filtered(installed, kind: .all, dependencies: .all, by: "cod").map(\.name) == ["codex"], "casks match by token")
        #expect(model.filtered(installed, kind: .all, dependencies: .all, by: "  ").count == 3, "blank search keeps everything")

        #expect(model.filtered(installed, kind: .formula, dependencies: .all, by: "").count == 2)
        #expect(model.filtered(installed, kind: .cask, dependencies: .all, by: "").map(\.name) == ["codex"])
    }

    @Test func theDependencyFilterSplitsByTheOnRequestFlag() async {
        let model = makeModel(snapshot: makeSnapshot(
            formulae: [
                makePackage("wget", onRequest: true),
                makePackage("openssl", onRequest: false),
                makePackage("pcre2", onRequest: false)
            ]
        ))
        model.activate()
        await model.waitUntilSettled()
        let installed = model.packages(for: .installed)

        #expect(model.filtered(installed, kind: .all, dependencies: .all, by: "").count == 3)
        #expect(model.filtered(installed, kind: .all, dependencies: .onlyDependencies, by: "").map(\.name) == ["openssl", "pcre2"])
        #expect(model.filtered(installed, kind: .all, dependencies: .excludeDependencies, by: "").map(\.name) == ["wget"])

        // The two filters compose: a formula-only view of just the
        // dependencies.
        #expect(model.filtered(installed, kind: .formula, dependencies: .onlyDependencies, by: "").count == 2)
    }

    @Test func aMissingOnRequestFlagKeepsEveryPackage() async {
        // Degraded mode: brew's JSON was unreadable, so no package carries
        // the flag. Both dependency filters must keep the whole list rather
        // than emptying it — the pane disables the filter in this state
        // anyway, and a filter that empties the list is the worse failure.
        let model = makeModel(snapshot: makeSnapshot(
            formulae: [makePackage("wget", onRequest: nil), makePackage("openssl", onRequest: nil)],
            detailsAvailable: false
        ))
        model.activate()
        await model.waitUntilSettled()
        let installed = model.packages(for: .installed)

        #expect(model.filtered(installed, kind: .all, dependencies: .onlyDependencies, by: "").count == 2)
        #expect(model.filtered(installed, kind: .all, dependencies: .excludeDependencies, by: "").count == 2)
    }

    @Test func dependentsAreTheReverseDependencyIndex() async throws {
        let model = makeModel(snapshot: makeSnapshot(
            formulae: [
                makePackage("openssl"),
                makePackage("curl", dependencies: ["openssl"]),
                makePackage("wget", dependencies: ["openssl", "ca-certificates"]),
                makePackage("ca-certificates")
            ]
        ))
        model.activate()
        await model.waitUntilSettled()

        let openssl = try #require(model.packages(for: .installed).first { $0.name == "openssl" })
        let dependents = model.dependents(of: openssl)
        #expect(dependents.map(\.name).sorted() == ["curl", "wget"])
        // A package never depends on itself in this index.
        #expect(!dependents.contains { $0.name == "openssl" })
    }

    @Test func selectedPackageFollowsTheSelection() async throws {
        let model = makeModel(snapshot: makeSnapshot(formulae: [makePackage("wget"), makePackage("node")]))
        model.activate()
        await model.waitUntilSettled()
        let packages = model.packages(for: .installed)
        #expect(model.selectedPackage(from: packages) == nil)

        // #require rather than a subscript: a load that never lands must
        // fail this test, not kill the whole suite with an index crash.
        model.selectPackage(try #require(packages.first))
        #expect(model.selectedPackage(from: packages)?.name == "wget")

        // A package removed by an uninstall must not leave a ghost selected.
        model.selectPackage(nil)
        #expect(model.selectedPackage(from: packages) == nil)
    }
}
