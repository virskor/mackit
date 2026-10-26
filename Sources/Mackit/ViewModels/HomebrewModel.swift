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
        case install
        case services
        case diagnostics
        case config
    }

    /// Which packages a list holds by kind — the pane's first segmented
    /// filter, the official GUIs' formula/cask split.
    enum KindFilter: String, CaseIterable, Sendable {
        case all
        case formula
        case cask
    }

    /// Which packages a list holds by their on-request flag — the pane's
    /// dropdown filter beside the kind band. The official GUIs offer only a
    /// "hide dependencies" toggle; the flip side — only what something else
    /// pulled in, which is what `brew autoremove` would take — deserves its
    /// own option beside it. Case order is the menu's display order:
    /// everything, then the packages the user asked for, then the ones
    /// pulled in as dependencies.
    enum DependencyFilter: String, CaseIterable, Sendable {
        case all
        case excludeDependencies
        case onlyDependencies
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

    // MARK: Install search

    /// What the install section's field holds, updated on every keystroke;
    /// the search itself is debounced off it.
    private(set) var searchQuery = ""
    /// Hits for the last completed search; nil before the first one and
    /// after the query is cleared.
    private(set) var searchResults: [HomebrewSearchResult]?
    private(set) var isSearching = false
    /// True when brew could not be read at all — distinct from "no matches",
    /// which is an empty result set.
    private(set) var searchFailed = false

    // MARK: Action state

    private(set) var runningAction: HomebrewAction?
    /// Result of the last finished action, shown as the page's notice until
    /// the next action replaces it.
    private(set) var outcome: HomebrewOutcome?
    /// Live progress of the running action — and, once it finishes, of the
    /// one just finished, so the status pill can still open its log.
    private(set) var progress: HomebrewProgress?
    /// Whether the status pill is on screen. Set on the same turn an action
    /// starts, because a view that reconstructs this from `runningAction`
    /// changes loses every action that finishes between two render passes —
    /// SwiftUI coalesces the two changes into "no change" and the pill never
    /// appears. Cleared by the dwell below once the action is done.
    private(set) var showsStatusPill = false
    /// Whether the pill's log popover is open. It lives beside the pill state
    /// because an open log pins the pill on screen.
    private(set) var showsActionLog = false
    /// The package awaiting uninstall confirmation. Uninstall is the one
    /// irreversible action on the page, so it goes through an explicit
    /// confirm dialog in the detail pane.
    private(set) var pendingUninstall: HomebrewPackage?

    private let inspect: () async -> HomebrewSnapshot?
    private let loadServices: () async -> [HomebrewService]?
    private let loadDiagnostics: () async -> String?
    private let loadConfig: () async -> [HomebrewConfigEntry]?
    /// Runs one action, reporting each output line as brew prints it. The
    /// line sink is how the page's progress pill stays live during a
    /// `brew upgrade` that runs for minutes.
    private let perform: (HomebrewAction, @escaping @MainActor @Sendable (String) -> Void) async -> HomebrewOutcome
    /// Searches the local index for the install section's query.
    private let runSearch: (String) async -> [HomebrewSearchResult]?

    private var loadTask: Task<Void, Never>?
    private var servicesTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var configTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// Takes the pill down once the dwell after a finished action expires.
    private var pillDismissTask: Task<Void, Never>?
    /// Bumped per search so a superseded search never clears the handle a
    /// newer one owns.
    private var searchGeneration = 0
    /// How long the finished action's pill stays up. Injected so tests can
    /// watch the dwell expire without waiting out the real ten seconds.
    private let pillDwell: Duration

    init(
        inspect: @escaping @MainActor () async -> HomebrewSnapshot? = { await HomebrewInspector.inspect() },
        loadServices: @escaping @MainActor () async -> [HomebrewService]? = { await HomebrewServices.list() },
        loadDiagnostics: @escaping @MainActor () async -> String? = { await HomebrewEnvironment.diagnostics() },
        loadConfig: @escaping @MainActor () async -> [HomebrewConfigEntry]? = { await HomebrewEnvironment.config() },
        perform: @escaping @MainActor (HomebrewAction, @escaping @MainActor @Sendable (String) -> Void) async -> HomebrewOutcome = { action, onLine in
            await HomebrewActions.run(
                action,
                run: HomebrewRunner.run,
                stream: HomebrewRunner.stream,
                onLine: onLine
            )
        },
        runSearch: @escaping @MainActor (String) async -> [HomebrewSearchResult]? = { await HomebrewSearch.search($0) },
        pillDwell: Duration = .seconds(10)
    ) {
        self.inspect = inspect
        self.loadServices = loadServices
        self.loadDiagnostics = loadDiagnostics
        self.loadConfig = loadConfig
        self.perform = perform
        self.runSearch = runSearch
        self.pillDwell = pillDwell
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
        loadTask = Task { [inspect, weak self] in
            guard let self else { return }
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
        case .installed, .upgrade, .install:
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
        servicesTask = Task { [loadServices, weak self] in
            guard let self else { return }
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
        diagnosticsTask = Task { [loadDiagnostics, weak self] in
            guard let self else { return }
            let diagnostics = await loadDiagnostics()
            guard !Task.isCancelled else { return }
            self.isLoadingDiagnostics = false
            self.diagnostics = diagnostics
        }
    }

    func refreshConfig() {
        configTask?.cancel()
        isLoadingConfig = true
        configTask = Task { [loadConfig, weak self] in
            guard let self else { return }
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
        // one, so a confirm dialog can never apply to a different package.
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
        progress = HomebrewProgress(action: action, total: plannedTotal(for: action))
        // The pill goes up on this same turn. Leaving it to the view means
        // deriving it from `runningAction`'s change notification, which
        // SwiftUI coalesces away when an action finishes before the next
        // render pass — the pill then never appears for that action at all.
        pillDismissTask?.cancel()
        pillDismissTask = nil
        showsStatusPill = true
        Task { [perform, weak self] in
            guard let self else { return }
            let outcome = await perform(action) { line in
                self.consumeLine(line)
            }
            guard !Task.isCancelled else { return }
            self.runningAction = nil
            self.outcome = outcome
            // The progress outlives the action so the status pill can still
            // open the log; the finish time freezes its elapsed readout.
            if var current = self.progress {
                current.finish()
                self.progress = current
            }
            self.schedulePillDismiss()
            guard outcome.succeeded else {
                // A failed action changes nothing; reloading would only hide
                // the failure behind an identical snapshot.
                return
            }
            switch action {
            case .cleanup, .autoremove, .upgradeAll, .upgrade, .uninstall, .install:
                self.reload()
            case .startService, .stopService, .restartService:
                self.refreshServices()
            }
        }
    }

    /// Opens or closes the action log. Closing it re-arms the dwell so the
    /// finished result stays reachable a little longer; opening it pins the
    /// pill (see `schedulePillDismiss`).
    func setActionLogVisible(_ visible: Bool) {
        showsActionLog = visible
        pillDismissTask?.cancel()
        pillDismissTask = nil
        if !visible, runningAction == nil, outcome != nil {
            schedulePillDismiss()
        }
    }

    /// Keeps the finished action's pill up long enough to read the result and
    /// open the log, then takes it down. The notice above the section content
    /// remains the durable record of the outcome.
    ///
    /// An open log pins the pill: the popover is anchored to it, so dismissing
    /// the pill mid-read would pull the popover out from under the reader.
    private func schedulePillDismiss() {
        pillDismissTask?.cancel()
        pillDismissTask = nil
        guard !showsActionLog else { return }
        pillDismissTask = Task { [weak self, pillDwell] in
            try? await Task.sleep(for: pillDwell)
            // `try?` swallows the cancellation error that pinning the pill
            // (an opening log, a new action) raises; without this guard the
            // fall-through dismisses the pill the cancel meant to keep.
            guard !Task.isCancelled else { return }
            self?.showsStatusPill = false
        }
    }

    /// The number of packages the action plans to touch — the progress bar's
    /// denominator, known before brew prints anything (it never states a
    /// total outside a dry run). Nil where only brew knows: autoremove
    /// decides what is unneeded as it goes, cleanup removes an unknown
    /// number of paths, and an install is a single opaque step brew reports
    /// no per-package lines for.
    private func plannedTotal(for action: HomebrewAction) -> Int? {
        switch action {
        case .upgradeAll:
            return snapshot?.outdated.count
        case .upgrade, .uninstall:
            return 1
        case .cleanup, .autoremove, .install, .startService, .stopService, .restartService:
            return nil
        }
    }

    /// Folds one streamed output line into the progress. Runs on the main
    /// actor — the runner's line callback hops there before calling in.
    private func consumeLine(_ line: String) {
        guard var current = progress else { return }
        current.append(line)
        progress = current
    }

    // MARK: Install search

    /// Live search entry: the install section's field calls this on every
    /// edit. The debounce lives here so the field stays a plain binding and
    /// the query survives section switches.
    func updateSearchQuery(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchTask = nil
            searchResults = nil
            isSearching = false
            searchFailed = false
            return
        }
        // A superseded search's failure must not outlive the keystroke that
        // replaced it.
        searchGeneration += 1
        searchFailed = false
        let generation = searchGeneration
        searchTask = Task { [runSearch, weak self] in
            // A keystroke a second apart would otherwise start a brew search
            // per character; brew takes a few hundred milliseconds to boot.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.isSearching = true
            let results = await runSearch(trimmed)
            guard !Task.isCancelled else { return }
            self.isSearching = false
            // nil is "brew could not be read"; an empty array is a real
            // "nothing matches" — the section shows a different state for
            // each.
            self.searchResults = results ?? []
            self.searchFailed = results == nil
            if self.searchGeneration == generation { self.searchTask = nil }
        }
    }

    /// Whether a search hit is already installed. The id — kind plus name —
    /// is the same identity the installed list uses, so a cask sharing a
    /// formula's name is its own package rather than a false "installed".
    func isInstalled(_ result: HomebrewSearchResult) -> Bool {
        snapshot?.allPackages.contains { $0.id == result.id } ?? false
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
        case .install, .services, .diagnostics, .config: return []
        }
    }

    /// The list a package pane shows: the section's packages, narrowed by the
    /// kind filter, then the dependency filter, then the search text.
    ///
    /// A nil on-request flag — only brew's JSON carries it, and degraded mode
    /// has none — is kept by both filters: an unknown flag never excludes a
    /// package, so the filters cannot empty the list when brew cannot tell.
    func filtered(
        _ packages: [HomebrewPackage],
        kind: KindFilter,
        dependencies: DependencyFilter,
        by text: String
    ) -> [HomebrewPackage] {
        var result: [HomebrewPackage]
        switch kind {
        case .all: result = packages
        case .formula: result = packages.filter { $0.kind == .formula }
        case .cask: result = packages.filter { $0.kind == .cask }
        }
        switch dependencies {
        case .all: break
        case .onlyDependencies: result = result.filter { $0.installedOnRequest != true }
        case .excludeDependencies: result = result.filter { $0.installedOnRequest != false }
        }
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return result }
        return result.filter { $0.name.lowercased().contains(needle) || $0.displayName.lowercased().contains(needle) }
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
        // A pending search counts even inside its debounce window: the task
        // holds the handle until it lands or is superseded.
        while isLoading || isLoadingServices || isLoadingDiagnostics || isLoadingConfig || runningAction != nil || isSearching || searchTask != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
