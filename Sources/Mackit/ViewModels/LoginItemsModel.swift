import AppKit
import Foundation
import MackitHelperKit

/// State model for the startup-items tool page.
///
/// The scan finds every startup item the system exposes to a third-party
/// app — per-user launch agents, machine-wide agents, machine-wide
/// daemons and the legacy login-items list — grouped by the app each one
/// belongs to, and the page toggles them one at a time or a whole app at
/// once. Changing a machine-wide daemon needs the privileged helper, so
/// the model owns that flow too: the first such toggle offers the
/// install, and the state of the helper is part of the page's state.
///
/// Every dependency is an injected closure, the same contract the other
/// tool models keep: the toggle logic, the helper gating and the grouping
/// are all testable without touching a real launchd. The snapshot
/// survives page switches — the scan belongs to the session, not to the
/// page being visible — and a rescan is the only thing that
/// re-enumerates.
@MainActor
@Observable
final class LoginItemsModel {
    /// The privileged helper's installation state, as the page shows it.
    enum HelperState: Equatable, Sendable {
        case notInstalled
        case installed(version: String, stale: Bool)

        var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }

        /// Whether a system-service change needs an install (or a
        /// reinstall) before it can go through. A missing helper and a
        /// stale one both qualify: the helper's behavior ships with the
        /// app, so an older daemon may not understand the current
        /// request set.
        var needsInstall: Bool {
            switch self {
            case .notInstalled: return true
            case .installed(_, let stale): return stale
            }
        }
    }

    /// A toggle waiting for the privileged helper to be installed — the
    /// change the user asked for, held while the install runs so it can
    /// be applied the moment the helper is in place.
    struct PendingChange: Equatable, Sendable {
        let itemIDs: [String]
        let enabled: Bool
    }

    /// A transient message the page shows above the list: an install
    /// failure, a refused toggle, a removed helper.
    struct Notice: Equatable, Identifiable {
        let id: Int
        let message: String
        let isError: Bool
    }

    // MARK: Scanned data

    private(set) var items: [LoginItem] = []
    private(set) var groups: [LoginItemGroup] = []
    private(set) var isLoading = false
    /// Whether a scan has landed at least once. `activate` uses it to
    /// scan only on the session's first visit.
    private(set) var hasScanned = false

    // MARK: View state

    /// The search field's content; filters groups by name, label and
    /// path.
    var searchText: String = ""
    /// The list's sort order.
    var sort: LoginItemSort = .name

    // MARK: Helper state

    private(set) var helperState: HelperState = .notInstalled
    /// The change waiting on a helper install. Non-nil drives the
    /// confirmation sheet.
    private(set) var pendingChange: PendingChange?
    /// Whether the privileged install is running — the sheet's spinner.
    private(set) var isInstallingHelper = false
    /// Whether the helper removal is running — the confirmation's
    /// spinner.
    private(set) var isRemovingHelper = false
    /// Whether the helper-removal confirmation is showing. Removing the
    /// helper tears down root-owned files behind a password of its own,
    /// so it is confirmed rather than one click from the status row.
    private(set) var isConfirmingHelperRemoval = false

    /// Whether the helper's files are in place but the daemon did not
    /// answer — a broken install (a daemon that died without launchd
    /// restarting it, say). The install flow repairs it by reinstalling,
    /// so the next system toggle goes through the install path instead
    /// of failing again. Cleared by a reinstall and by every fresh state
    /// read.
    private(set) var helperUnreachable = false

    // MARK: Action state

    /// Item ids whose toggle is in flight; the row shows a spinner.
    private(set) var runningItemIDs: Set<String> = []
    /// The transient message above the list, until the next action or a
    /// dismiss replaces it.
    private(set) var notice: Notice?

    /// Bumped per notice so repeated identical messages still re-render.
    private var noticeCounter = 0

    // MARK: Dependencies

    /// Enumerates the system's startup items. Runs off the main thread
    /// by its default implementation — app discovery is seconds of IO.
    private let scan: () async -> [LoginItem]
    /// Applies one item's enabled state.
    private let apply: (LoginItem, Bool) async -> HelperOutcome
    /// Reads the helper's on-disk installation state.
    private let readHelperState: @Sendable () -> HelperClient.InstalledState
    /// Runs the privileged install. Blocking for as long as the password
    /// dialog is up, so the model runs it detached.
    private let installHelper: @Sendable () -> HelperInstaller.Outcome
    /// Removes the helper.
    private let uninstallHelper: @Sendable () async -> HelperOutcome
    /// The running app's version, compared against the installed
    /// helper's recorded one.
    private let appVersion: String
    /// The real icon of an app bundle path.
    private let iconForPath: @MainActor (String) -> NSImage?

    private var scanTask: Task<Void, Never>?

    /// The app-icon cache, capped with FIFO eviction for the same reason
    /// the uninstall tool's is: every cached NSImage carries its full
    /// representation set, and a machine's startup-item list has no
    /// bound on how many distinct apps it can name.
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var iconCacheOrder: [String] = []
    private let iconCacheCapacity = 128

    init(
        scan: @escaping () async -> [LoginItem] = {
            // Discovery and the launchctl state queries share one
            // detached task: enumerating installed apps on the main
            // thread would freeze the UI, the same reason the uninstall
            // tool's scan detaches.
            await Task.detached(priority: .utility) {
                await LoginItemScanner.scan()
            }.value
        },
        apply: @escaping (LoginItem, Bool) async -> HelperOutcome = { item, enabled in
            await LoginItemActions.setEnabled(item, enabled: enabled)
        },
        readHelperState: @escaping @Sendable () -> HelperClient.InstalledState = HelperClient.installedState,
        installHelper: @escaping @Sendable () -> HelperInstaller.Outcome = HelperInstaller.install,
        uninstallHelper: @escaping @Sendable () async -> HelperOutcome = HelperClient.uninstall,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
        iconForPath: @escaping @MainActor (String) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0) }
    ) {
        self.scan = scan
        self.apply = apply
        self.readHelperState = readHelperState
        self.installHelper = installHelper
        self.uninstallHelper = uninstallHelper
        self.appVersion = appVersion
        self.iconForPath = iconForPath
    }

    // MARK: Lifecycle

    /// Called when the sidebar selects the tool. Scans once per session;
    /// coming back to a scanned list is instant. The helper's state is
    /// probed on the same visit so the page never shows a stale
    /// "not installed" for an installed helper.
    func activate() {
        refreshHelperState()
        guard !hasScanned, !isLoading else { return }
        rescan()
    }

    /// Re-enumerates the system's startup items, replacing any in-flight
    /// scan.
    func rescan() {
        scanTask?.cancel()
        isLoading = true
        let startedAt = ContinuousClock.now
        scanTask = Task { [scan] in
            let result = await scan()
            guard !Task.isCancelled else { return }
            self.isLoading = false
            self.hasScanned = true
            self.items = result
            self.groups = Self.regroup(result, sort: self.sort)
            MackitLog.loginItems.info("login items scan: \(result.count, privacy: .public) items in \(self.groups.count, privacy: .public) groups, took \(MackitLog.duration(.now - startedAt), privacy: .public)")
        }
    }

    /// Re-reads the helper's installation state and staleness. Also
    /// clears the unreachable mark: a fresh state read is the model
    /// saying "as far as the disk is concerned, here is where we stand".
    func refreshHelperState() {
        helperUnreachable = false
        switch readHelperState() {
        case .notInstalled:
            helperState = .notInstalled
        case .installed(let version):
            let stale = HelperVersion.isStale(installed: version, bundled: appVersion)
            helperState = .installed(version: version, stale: stale)
        }
    }

    // MARK: Derived data

    /// The groups the search field leaves, in sort order.
    var visibleGroups: [LoginItemGroup] {
        LoginItemScanner.filter(groups, search: searchText)
    }

    /// Whether the page has any system daemon at all — the helper's
    /// section is only worth showing when there is something it manages.
    var hasSystemDaemons: Bool {
        items.contains { $0.kind == .systemDaemon }
    }

    /// The group an item belongs to, for the row's expansion state.
    func group(containing item: LoginItem) -> LoginItemGroup? {
        groups.first { $0.items.contains(item) }
    }

    /// The real icon of an app bundle, cached per path. nil for anything
    /// without a path; the view falls back to a kind symbol.
    func icon(forPath path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = iconCache[path] { return cached }
        guard let icon = iconForPath(path) else { return nil }
        if iconCacheOrder.count >= iconCacheCapacity {
            iconCache.removeValue(forKey: iconCacheOrder.removeFirst())
        }
        iconCacheOrder.append(path)
        iconCache[path] = icon
        return icon
    }

    // MARK: Toggling

    /// Whether an item's toggle is in flight.
    func isRunning(_ item: LoginItem) -> Bool { runningItemIDs.contains(item.id) }

    /// Toggles one item. A machine-wide daemon whose helper is not in
    /// place (or is stale) does not switch here: the change is held as a
    /// pending change and the confirmation sheet asks for the install
    /// first.
    func toggle(_ item: LoginItem, enabled: Bool) {
        guard item.isEnabled != enabled else { return }
        // An installed-but-unreachable helper is a broken install the
        // install flow repairs, so it takes the same path.
        if item.needsHelper, helperState.needsInstall || helperUnreachable {
            pendingChange = PendingChange(itemIDs: [item.id], enabled: enabled)
            return
        }
        runToggle(itemIDs: [item.id], enabled: enabled)
    }

    /// Toggles every item of a group at once — the app-level switch.
    /// A group holding daemons with no helper in place goes through the
    /// same install-first path as a single daemon toggle.
    func setGroupEnabled(_ group: LoginItemGroup, enabled: Bool) {
        let ids = group.items.map(\.id)
        guard !ids.isEmpty else { return }
        let needsHelper = group.items.contains { $0.needsHelper }
        if needsHelper, helperState.needsInstall || helperUnreachable {
            pendingChange = PendingChange(itemIDs: ids, enabled: enabled)
            return
        }
        runToggle(itemIDs: ids, enabled: enabled)
    }

    /// Applies a held change immediately, without the install gate — the
    /// path a test or a caller with the helper already in place takes.
    func runToggle(itemIDs: [String], enabled: Bool) {
        let targets = items.filter { itemIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        runningItemIDs.formUnion(targets.map(\.id))
        Task { [apply] in
            var failures: [String] = []
            for item in targets {
                let outcome = await apply(item, enabled)
                self.runningItemIDs.remove(item.id)
                if outcome.succeeded {
                    self.setItemEnabled(item.id, enabled: enabled)
                } else if outcome.unreachable {
                    // The daemon did not answer: its files may still be
                    // in place, which the install flow can repair. The
                    // next toggle opens it.
                    self.helperUnreachable = true
                    failures.append(L10n.tr("loginItems.helper.unresponsive"))
                } else {
                    failures.append(outcome.failure ?? L10n.tr("loginItems.action.failed"))
                }
            }
            if !failures.isEmpty {
                // One notice per group of failures: a master switch over
                // five items that all failed is one problem, not five.
                self.present(failures.joined(separator: "\n"), isError: true)
            }
        }
    }

    /// Confirms the pending change after the helper install: installs,
    /// then applies the change the install was for.
    ///
    /// The install blocks for as long as the password dialog is up, so
    /// it runs on a detached task; a cancelled dialog is a notice, not
    /// an error, and every switch stays where it was.
    func confirmPendingChange() {
        guard let pending = pendingChange, !isInstallingHelper else { return }
        isInstallingHelper = true
        Task { [installHelper] in
            let outcome = await Task.detached { installHelper() }.value
            self.isInstallingHelper = false
            self.pendingChange = nil
            switch outcome {
            case .installed:
                self.refreshHelperState()
                self.helperUnreachable = false
                MackitLog.loginItems.info("privileged helper installed")
                self.runToggle(itemIDs: pending.itemIDs, enabled: pending.enabled)
            case .cancelled:
                self.present(L10n.tr("loginItems.helper.installCancelled"), isError: false)
            case .failed(let message):
                MackitLog.loginItems.error("privileged helper install failed: \(message, privacy: .public)")
                self.present(message, isError: true)
            }
        }
    }

    /// Cancels the pending change; every switch stays where it was.
    func cancelPendingChange() {
        pendingChange = nil
    }

    // MARK: Helper lifecycle

    /// Asks whether to remove the privileged helper — the status row's
    /// action opens the confirmation, it does not remove anything yet.
    func requestHelperRemoval() {
        guard helperState.isInstalled else { return }
        isConfirmingHelperRemoval = true
    }

    /// Removes the privileged helper: its daemon plist, its binary and
    /// its launchd registration.
    func removeHelper() {
        isConfirmingHelperRemoval = false
        isRemovingHelper = true
        Task { [uninstallHelper] in
            let outcome = await uninstallHelper()
            self.isRemovingHelper = false
            if outcome.succeeded {
                self.refreshHelperState()
                self.present(L10n.tr("loginItems.helper.removed"), isError: false)
                MackitLog.loginItems.info("privileged helper removed")
            } else {
                self.present(outcome.failure ?? L10n.tr("loginItems.helper.removeFailed"), isError: true)
            }
        }
    }

    func cancelHelperRemoval() {
        isConfirmingHelperRemoval = false
    }

    // MARK: Notices

    func dismissNotice() {
        notice = nil
    }

    private func present(_ message: String, isError: Bool) {
        noticeCounter += 1
        notice = Notice(id: noticeCounter, message: message, isError: isError)
    }

    // MARK: Internals

    /// Flips one item's enabled state in place, regrouping so the
    /// aggregate status and sort order follow.
    private func setItemEnabled(_ itemID: String, enabled: Bool) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].isEnabled = enabled
        groups = Self.regroup(items, sort: sort)
    }

    /// Regroups the flat item list. Pure, so the model's mutations and
    /// the tests share one implementation.
    static func regroup(_ items: [LoginItem], sort: LoginItemSort) -> [LoginItemGroup] {
        LoginItemScanner.group(items, sort: sort)
    }

    /// Test seam: waits until no scan, toggle, helper install or helper
    /// removal is in flight. The install and removal count even though
    /// they run on detached or fire-and-forget tasks: their flags are
    /// set synchronously when the work starts and cleared when it
    /// finishes, so the flags cover the whole span.
    func waitUntilSettled() async {
        while isLoading || !runningItemIDs.isEmpty || isInstallingHelper || isRemovingHelper {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
