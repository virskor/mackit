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
    }

    private func makePackage(
        _ name: String,
        kind: HomebrewPackage.Kind = .formula,
        outdated: Bool = false,
        dependencies: [String] = []
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
            installedOnRequest: true,
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
        services: [HomebrewService]? = [],
        outcome: HomebrewOutcome = HomebrewOutcome(action: .cleanup, measure: 512, failure: nil)
    ) -> HomebrewModel {
        HomebrewModel(
            inspect: {
                counters.inspect += 1
                return snapshot
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
            perform: { action in
                counters.actions.append(action)
                return outcome
            }
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

    @Test func packagesPerSectionAndFiltering() {
        let model = makeModel(snapshot: makeSnapshot(
            formulae: [makePackage("wget", outdated: true), makePackage("node")],
            casks: [makePackage("codex", kind: .cask, outdated: true)]
        ))

        #expect(model.packages(for: .installed).count == 3)
        #expect(model.packages(for: .upgrade).count == 2)
        #expect(model.packages(for: .services).isEmpty)

        let installed = model.packages(for: .installed)
        #expect(model.filtered(installed, by: "WGET").map(\.name) == ["wget"])
        #expect(model.filtered(installed, by: "cod").map(\.name) == ["codex"], "casks match by token")
        #expect(model.filtered(installed, by: "  ").count == 3, "blank search keeps everything")
    }

    @Test func dependentsAreTheReverseDependencyIndex() throws {
        let model = makeModel(snapshot: makeSnapshot(
            formulae: [
                makePackage("openssl"),
                makePackage("curl", dependencies: ["openssl"]),
                makePackage("wget", dependencies: ["openssl", "ca-certificates"]),
                makePackage("ca-certificates")
            ]
        ))

        let openssl = try #require(model.packages(for: .installed).first { $0.name == "openssl" })
        let dependents = model.dependents(of: openssl)
        #expect(dependents.map(\.name).sorted() == ["curl", "wget"])
        // A package never depends on itself in this index.
        #expect(!dependents.contains { $0.name == "openssl" })
    }

    @Test func selectedPackageFollowsTheSelection() {
        let model = makeModel(snapshot: makeSnapshot(formulae: [makePackage("wget"), makePackage("node")]))
        let packages = model.packages(for: .installed)
        #expect(model.selectedPackage(from: packages) == nil)

        model.selectPackage(packages[0])
        #expect(model.selectedPackage(from: packages)?.name == "wget")

        // A package removed by an uninstall must not leave a ghost selected.
        model.selectPackage(nil)
        #expect(model.selectedPackage(from: packages) == nil)
    }
}
