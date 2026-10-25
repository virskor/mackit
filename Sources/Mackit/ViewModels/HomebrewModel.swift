import Foundation

/// State model for the Homebrew manager tool page.
///
/// The page's sections mirror the official Homebrew GUIs' information
/// architecture: what is installed, what can be upgraded, the services brew
/// manages, and the two support facts (`brew doctor` / `brew config`). Each
/// section loads its own data on first visit and keeps it for the session —
/// the snapshot survives page switches, so coming back is instant, and only
/// an explicit refresh or a finished action re-queries.
///
/// Every query and every action is an injected closure, so the page's
/// contracts are testable without a real Homebrew installation; the defaults
/// are the real ones.
@MainActor
@Observable
final class HomebrewModel {
    /// The page's sections.
    enum Section: String, CaseIterable, Sendable {
        case installed
        case upgrade
        case services
        case diagnostics
        case config
    }

    // MARK: Section state

    private(set) var section: Section = .installed
    /// The package the detail pane shows; nil means the pane shows its
    /// "no selection" state.
    private(set) var selectedPackageID: String?

    // MARK: Installed data

    private(set) var isLoading = false
    /// The loaded installation; nil before the first load lands, and nil
    /// again when Homebrew turns out not to be installed.
    private(set) var snapshot: HomebrewSnapshot?
    /// True once a load has confirmed Homebrew is not installed — the page
    /// shows the install prompt instead of an empty manager.
    private(set) var isNotInstalled = false

    // MARK: Services

    private(set) var isLoadingServices = false
    /// nil until the services section has loaded once; an empty array is a
    /// real "no services" answer.
    private(set) var services: [HomebrewService]?
    private(set) var servicesFailed = false

    // MARK: Diagnostics & config

    private(set) var isLoadingDiagnostics = false
    private(set) var diagnostics: String?
    private(set) var isLoadingConfig = false
    private(set) var config: [HomebrewConfigEntry]?

    // MARK: Action state

    private(set) var runningAction: HomebrewAction?
    /// Result of the last finished action, shown as the page's notice until
    /// the next action replaces it.
    private(set) var outcome: HomebrewOutcome?
    /// The package awaiting uninstall confirmation. Uninstall is the one
    /// irreversible action on the page, so it goes through an explicit
    /// confirm step in the detail pane.
    private(set) var pendingUninstall: HomebrewPackage?

    private let inspect: () async -> HomebrewSnapshot?
    private let loadServices: () async -> [HomebrewService]?
    private let loadDiagnostics: () async -> String?
    private let loadConfig: () async -> [HomebrewConfigEntry]?
    private let perform: (HomebrewAction) async -> HomebrewOutcome

    private var loadTask: Task<Void, Never>?
    private var servicesTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var configTask: Task<Void, Never>?

    init(
        inspect: @escaping @MainActor () async -> HomebrewSnapshot? = { await HomebrewInspector.inspect() },
        loadServices: @escaping @MainActor () async -> [HomebrewService]? = { await HomebrewServices.list() },
        loadDiagnostics: @escaping @MainActor () async -> String? = { await HomebrewEnvironment.diagnostics() },
        loadConfig: @escaping @MainActor () async -> [HomebrewConfigEntry]? = { await HomebrewEnvironment.config() },
        perform: @escaping @MainActor (HomebrewAction) async -> HomebrewOutcome = { await HomebrewActions.run($0) }
    ) {
        self.inspect = inspect
        self.loadServices = loadServices
        self.loadDiagnostics = loadDiagnostics
        self.loadConfig = loadConfig
        self.perform = perform
    }

    // MARK: Lifecycle

    /// Called when the sidebar selects the tool. Loads the installed list
    /// once per session; every other section loads on its own first visit.
    func activate() {
        guard snapshot == nil, !isNotInstalled, !isLoading else { return }
        reload()
    }

    /// Re-queries the installed list, replacing any in-flight load.
    func reload() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [inspect] in
            let snapshot = await inspect()
            guard !Task.isCancelled else { return }
            self.isLoading = false
            self.snapshot = snapshot
            self.isNotInstalled = snapshot == nil
            // A selected package that an uninstall just removed must not
            // leave the detail pane showing a ghost.
            if let selectedPackageID, snapshot?.allPackages.contains(where: { $0.id == selectedPackageID }) != true {
                self.selectedPackageID = nil
            }
        }
    }

    /// Switches sections, loading the section's data on first visit.
    func showSection(_ section: Section) {
        self.section = section
        switch section {
        case .installed, .upgrade:
            break
        case .services:
            if services == nil, !isLoadingServices { refreshServices() }
        case .diagnostics:
            if diagnostics == nil, !isLoadingDiagnostics { refreshDiagnostics() }
        case .config:
            if config == nil, !isLoadingConfig { refreshConfig() }
        }
    }

    func refreshServices() {
        servicesTask?.cancel()
        isLoadingServices = true
        servicesFailed = false
        servicesTask = Task { [loadServices] in
            let services = await loadServices()
            guard !Task.isCancelled else { return }
            self.isLoadingServices = false
            self.services = services ?? []
            self.servicesFailed = services == nil
        }
    }

    func refreshDiagnostics() {
        diagnosticsTask?.cancel()
        isLoadingDiagnostics = true
        diagnosticsTask = Task { [loadDiagnostics] in
            let diagnostics = await loadDiagnostics()
            guard !Task.isCancelled else { return }
            self.isLoadingDiagnostics = false
            self.diagnostics = diagnostics
        }
    }

    func refreshConfig() {
        configTask?.cancel()
        isLoadingConfig = true
        configTask = Task { [loadConfig] in
            let config = await loadConfig()
            guard !Task.isCancelled else { return }
            self.isLoadingConfig = false
            self.config = config
        }
    }

    // MARK: Selection

    func selectPackage(_ package: HomebrewPackage?) {
        selectedPackageID = package?.id
        // Switching the subject clears a pending confirmation for the old
        // one, so a confirm row can never apply to a different package.
        if pendingUninstall?.id != package?.id { pendingUninstall = nil }
    }

    // MARK: Actions

    /// Runs a management action, then refreshes whatever it could have
    /// changed. A second action is ignored while one runs — `brew upgrade`
    /// takes minutes and overlapping invocations would fight over the same
    /// Cellar.
    func run(_ action: HomebrewAction) {
        guard runningAction == nil else { return }
        runningAction = action
        outcome = nil
        pendingUninstall = nil
        Task { [perform] in
            let outcome = await perform(action)
            guard !Task.isCancelled else { return }
            self.runningAction = nil
            self.outcome = outcome
            guard outcome.succeeded else {
                // A failed action changes nothing; reloading would only hide
                // the failure behind an identical snapshot.
                return
            }
            switch action {
            case .cleanup, .autoremove, .upgradeAll, .upgrade, .uninstall:
                self.reload()
            case .startService, .stopService, .restartService:
                self.refreshServices()
            }
        }
    }

    /// Asks for uninstall confirmation for a package.
    func requestUninstall(_ package: HomebrewPackage) {
        pendingUninstall = package
    }

    func cancelUninstall() {
        pendingUninstall = nil
    }

    func confirmUninstall() {
        guard let package = pendingUninstall else { return }
        run(.uninstall(package.kind, package.name))
    }

    // MARK: Derived data

    /// The section's package list: everything installed, or only what is out
    /// of date.
    func packages(for section: Section) -> [HomebrewPackage] {
        guard let snapshot else { return [] }
        switch section {
        case .installed: return snapshot.allPackages
        case .upgrade: return snapshot.outdated
        case .services, .diagnostics, .config: return []
        }
    }

    func filtered(_ packages: [HomebrewPackage], by text: String) -> [HomebrewPackage] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return packages }
        return packages.filter { $0.name.lowercased().contains(needle) || $0.displayName.lowercased().contains(needle) }
    }

    func selectedPackage(from packages: [HomebrewPackage]) -> HomebrewPackage? {
        guard let selectedPackageID else { return nil }
        return packages.first { $0.id == selectedPackageID }
    }

    /// Packages that depend on this one — the reverse index of the installed
    /// list's dependencies. Non-empty means an uninstall needs `--ignore-
    /// dependencies` or a dependent removed first, which is what the official
    /// GUIs flag as "blocks uninstall".
    func dependents(of package: HomebrewPackage) -> [HomebrewPackage] {
        guard let snapshot else { return [] }
        return snapshot.allPackages.filter { $0.id != package.id && $0.dependencies.contains(package.name) }
    }

    /// Test seam: waits until no load or action is in flight. Same polling
    /// contract as `DiskAnalysisModel.waitUntilSettled`.
    func waitUntilSettled() async {
        while isLoading || isLoadingServices || isLoadingDiagnostics || isLoadingConfig || runningAction != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
