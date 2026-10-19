import Foundation
import Sparkle

/// The auto-update controller: a thin wrapper around Sparkle.
///
/// It has only three responsibilities:
/// 1. Decide whether to start the updater based on `SUFeedURL` in Info.plist — dev builds have no
///    feed configured, Sparkle does not start at all, and the settings page hides update-related rows;
/// 2. Expose the updater's bindable state (auto-check / auto-download / last check time /
///    whether a check is possible) to the settings page and the menu;
/// 3. Forward the "Check for Updates" action to Sparkle.
///
/// After a new version is found, the download, EdDSA signature verification,
/// code signature validation, bundle replacement and restart are all handled
/// by Sparkle's standard UI; none of that is re-implemented here, nor is a
/// custom update flow drawn.
///
/// The update package and the host app must be signed with the same
/// Developer ID identity, and the feed must use HTTPS; both are guaranteed
/// by the release script (Scripts/build-update.sh).
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    // MARK: - Configuration

    /// Whether the update source is configured. Without `SUFeedURL` (a dev build
    /// that has not set `MACKIT_UPDATE_FEED_URL`), Sparkle has nothing to check
    /// and the controller is not enabled at all.
    var isEnabled: Bool {
        Self.isEnabled(feedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
    }

    /// The rule for deciding the feed URL is a separate function: nil / empty
    /// string both count as unconfigured, silently taking the "no updates"
    /// branch when the build script forgets to set the environment variable. A
    /// pure function that touches no isolated state, hence nonisolated.
    nonisolated static func isEnabled(feedURL: String?) -> Bool {
        guard let feedURL else { return false }
        return !feedURL.isEmpty
    }

    // MARK: - Observable state

    /// The last check time; nil if never checked.
    @Published private(set) var lastCheckDate: Date?

    /// Whether a check can currently be initiated. Sparkle sets this to false
    /// while a check is in progress or right after an automatic update runs, and
    /// the settings page's button is disabled accordingly.
    @Published private(set) var canCheckForUpdates = false

    // MARK: - Sparkle

    /// Sparkle's standard controller; stays nil when not enabled.
    private var standardController: SPUStandardUpdaterController?

    private override init() {
        super.init()
    }

    /// Start the updater (if configured). Called in `applicationDidFinishLaunching` —
    /// Sparkle requires the startup timing to be no earlier than app launch completion.
    func startIfNeeded() {
        guard isEnabled, standardController == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        // startUpdater does not throw: configuration errors (unreachable feed,
        // signature anomalies, etc.) are logged by Sparkle itself, which pops a
        // "contact the developer" prompt; here we only record the successful start.
        controller.startUpdater()
        standardController = controller
        refresh()
        if let feedURL = controller.updater.feedURL {
            MackitLog.updates.info("更新器已启动，feed：\(feedURL.absoluteString, privacy: .public)")
        }
    }

    /// Trigger a check initiated by the user. Called by the settings page button and the App menu.
    func checkForUpdates() {
        standardController?.checkForUpdates(nil)
    }

    /// The auto-check for updates switch, wired directly to Sparkle's corresponding property (persisted in user defaults).
    var automaticallyChecksForUpdates: Bool {
        get { standardController?.updater.automaticallyChecksForUpdates ?? false }
        set { standardController?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// The auto-download updates switch: silently download after finding a new version, then ask about installing once the download completes.
    var automaticallyDownloadsUpdates: Bool {
        get { standardController?.updater.automaticallyDownloadsUpdates ?? false }
        set { standardController?.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Refresh the observable state. Called by the settings page's `onAppear` and at the end of every check cycle.
    func refresh() {
        lastCheckDate = standardController?.updater.lastUpdateCheckDate
        canCheckForUpdates = standardController?.updater.canCheckForUpdates ?? false
    }

    /// The "Last Check" row shown in the settings page: a fixed message when
    /// never checked, otherwise "Last Check: <relative time>". The relative
    /// time is handed to `Formatters.relative`.
    func lastCheckDescription() -> String {
        Self.lastCheckDescription(for: lastCheckDate)
    }

    /// The pure function form (takes a date rather than reading state), making
    /// it easy to test both branches. `Formatters.relative` is confined to the
    /// main thread, so the same isolation is kept.
    @MainActor
    static func lastCheckDescription(for date: Date?) -> String {
        guard let date else {
            return L10n.tr("settings.update.lastCheckNever")
        }
        return L10n.fmt("settings.update.lastCheck", Formatters.relative(date))
    }
}

// MARK: - Update cycle callbacks

extension UpdateController: SPUUpdaterDelegate {
    /// Refresh UI state after every check cycle ends (whether it succeeded or
    /// failed, whether a new version was found or not).
    ///
    /// Obj-C protocol methods are nonisolated and cannot touch @MainActor
    /// published properties directly; hop back to the main task to refresh.
    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        Task { @MainActor [weak self] in
            self?.refresh()
        }
        if let error {
            MackitLog.updates.error("更新检查周期结束（失败）：\(error.localizedDescription, privacy: .public)")
        } else {
            MackitLog.updates.info("更新检查周期结束")
        }
    }

    /// A valid update was found: Sparkle will show its own update UI next; here we only leave a log.
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MackitLog.updates.info("发现新版本 \(item.displayVersionString, privacy: .public)")
    }
}
