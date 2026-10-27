import SwiftUI

/// App entry dispatch. The same binary is packaged into two bundles, with
/// roles assigned by bundle ID:
///
///   - `cn.mingcui.mackit` (Mackit.app, regular): the main app — main
///     window + scan/clean + Sparkle. Closing the window quits, and the
///     Dock icon disappears along with the process.
///   - `cn.mingcui.mackit.agent` (MackitAgent.app, LSUIElement):
///     the tray agent, permanently in the menu bar, only doing the icon,
///     panel and system monitoring, never entering the Dock.
///
/// The two processes cooperate via `AppBridge` (distributed notifications
/// + App Group shared settings). The reason this is not one process
/// switching activation policy at runtime: every switch makes macOS
/// rebuild the menu bar and add/remove Dock tiles, and the menu bar
/// flashing and the whole row of Dock icons shifting sideways both come
/// from this; with each of the two processes in its own fixed form,
/// neither of these happens anymore.
///
/// A dispatch struct is used instead of attaching @main to each of the two
/// Apps: a module can have only one @main; and SceneBuilder does not
/// support if branches, so the same body cannot assemble scenes by role.
/// The whole entry is isolated to the main actor: `appliedLanguage` is a
/// mutable static written at launch and read at runtime, which under
/// strict concurrency may only be touched on the main thread (menu bar
/// labels and settings broadcasts both happen only on the main thread).
@MainActor
@main
struct MackitEntry {
    /// The language selection applied when the agent starts up. If the
    /// choice in shared settings changes while running, the agent must be
    /// restarted (see `relaunchIfLanguageChanged`).
    private static var appliedLanguage: AppLanguage = .system

    @MainActor
    static func main() {
        if AppIdentity.currentProcessIsAgent {
            // The moment a login item is registered, launchd immediately
            // launches the agent; if an instance is already running at
            // that point (just launched by the main app), the two
            // processes would each create a menu bar icon.
            // Only one instance is allowed per bundle ID; the latecomer
            // exits directly.
            if AppBridge.hasOtherAgentInstance() {
                exit(0)
            }
            // The language must be applied before any Bundle localization
            // query: once preferredLocalizations has been computed it is
            // cached, and changing AppleLanguages afterwards has no effect.
            appliedLanguage = applySharedLanguage()
            MackitAgentApp.main()
        } else {
            MackitApp.main()
        }
    }

    /// The language selection in shared settings; defaults to `.system`
    /// when nothing has been recorded.
    @MainActor
    private static func sharedLanguage() -> AppLanguage {
        let raw = SharedStore.loadSettings()["appLanguage"] as? String ?? ""
        return AppLanguage(rawValue: raw) ?? .system
    }

    /// Writes the language selection from shared settings into this
    /// process's `AppleLanguages`, returning the applied selection.
    ///
    /// The two processes' UserDefaults are different domains (different
    /// bundle IDs), so the AppleLanguages the main app writes into its own
    /// domain is invisible to the agent, while both the menu bar labels and
    /// the tray panel are drawn by the agent — the language selection is
    /// therefore additionally stored by the main app into shared settings,
    /// which the agent reads out and applies into its own process at
    /// startup.
    @MainActor
    private static func applySharedLanguage() -> AppLanguage {
        let language = sharedLanguage()
        AppLanguage.store(language)
        return language
    }

    /// Restart the agent when the language selection changes (only the
    /// agent process calls this).
    ///
    /// The process's resolved language cannot be changed at runtime, so
    /// the whole process has to start over. First let a shell launch the
    /// new instance after a delay, then quit ourselves: by the time the
    /// new one starts the old one is already gone, so the single-instance
    /// check (`hasOtherAgentInstance`) will not mistake a predecessor that
    /// has not yet fully exited for a live peer. The same delayed-restart
    /// technique as the main app's `restartApp`.
    @MainActor
    static func relaunchIfLanguageChanged() {
        guard AppIdentity.currentProcessIsAgent else { return }
        let stored = sharedLanguage()
        guard stored != appliedLanguage else { return }

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        let escaped = Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        relaunch.arguments = ["-c", "sleep 0.6; open '\(escaped)'"]
        try? relaunch.run()
        MackitLog.ui.info("language selection changed to \(stored.rawValue, privacy: .public): restarting tray agent")
        // Defer quitting by one runloop turn: the shell has already been
        // launched and the notifications have been sent
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

/// Main app: single window + menu commands.
struct MackitApp: App {
    @State private var vm = AppViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Single-window scene. Must use `Window` rather than `WindowGroup`:
        // WindowGroup's `openWindow(id:)` opens a new window even when it
        // hits the same id (tested, including the one inside onAppear at
        // cold launch), so every "give me the main window" command from
        // the tray adds another window — this is where the two windows
        // popping up when clicking "Hardware details" come from. `Window`
        // is a singleton scene; openWindow only focuses (rebuilding the
        // window when it has been closed), so there is always just one
        // window.
        //
        // Closing the window quits the main app: the Dock icon disappears
        // along with the process, and the menu bar monitoring is sustained
        // independently by the agent.
        Window("Mackit", id: "main") {
            MainWindowRootView()
                .environment(vm)
        }
        .defaultSize(width: 980, height: 660)
        // The title bar no longer holds anything (the control strip has
        // all moved into the right-hand card), so removing the whole bar
        // lets the sidebar and cards extend right to the top of the
        // window. The system traffic lights and the sidebar toggle float
        // above the content; the 28pt top padding of the sidebar is the
        // space reserved for them.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandMenu(L10n.tr("menu.scan")) {
                Button(L10n.tr("menu.scan.start")) { vm.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(vm.phase == .scanning)

                Divider()

                Button(L10n.tr("menu.scan.selectAllSafe")) { vm.selectAllSafe() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(vm.items.isEmpty)

                Divider()

                Button(L10n.tr("menu.scan.cleanSelected")) { vm.requestClean() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(vm.scopeSelectedItems.isEmpty)
            }

            CommandGroup(after: .sidebar) {
                Toggle(L10n.tr("menu.safeOnly"), isOn: $vm.safeOnly)
            }

            // Settings is now a sidebar row + an embedded display in the
            // main window; there is no separate Settings scene. The App
            // menu item and ⌘, are kept here, and clicking them focuses
            // the main window and switches to the settings page.
            CommandGroup(replacing: .appSettings) {
                Button(L10n.tr("menubar.settings")) {
                    openWindow(id: "main")
                    vm.showSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            // "Check for updates" is placed below the App menu's settings
            // item, consistent with macOS convention.
            // Disabled when no feed is configured (development builds),
            // so the user does not click and get no response.
            CommandGroup(after: .appSettings) {
                Button(L10n.tr("menu.checkForUpdates")) {
                    UpdateController.shared.checkForUpdates()
                }
                .disabled(!UpdateController.shared.isEnabled)
            }
        }
    }
}

/// The main window's root view: mounts ContentView, and performs the
/// launch-time and post-close window policy.
private struct MainWindowRootView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .onAppear {
                // For the AppKit side (Dock clicks, IPC command handler)
                // to rebuild / focus the window: only an openWindow from
                // within the scene can bring a closed window back up.
                // Stored on AppDelegate's static property, so it remains
                // valid after the main window closes.
                AppDelegate.reopenMainWindow = {
                    MackitLog.ui.info("rebuild / focus main window (openWindow)")
                    openWindow(id: "main")
                }
                AppDelegate.viewModel = vm
                // Cold-start compensation: the agent queued a command
                // while the main app was not yet up (at the moment
                // "Open main window" was clicked in the tray, the main
                // app was not running); execute it now.
                if let pending = AppBridge.takePendingCommand() {
                    AppDelegate.handleCommand(pending)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                // When hidden wholesale by ⌘H etc. the window is likewise
                // invisible, but the user will bring it back from the
                // Dock, so that does not count as closing; only quit when
                // the window is truly gone.
                guard !NSApp.isHidden else { return }
                MackitLog.ui.info("main window closed: quitting main app, tray agent stays resident")
                // Before quitting, broadcast the last scan state: the
                // total reclaimable size and item count are left as-is for
                // the tray panel, while the selection is voided along with
                // the main window session (see scanStateForExit).
                AppBridge.postScanState(vm.scanStateForExit())
                // Distributed notifications are delivered asynchronously;
                // the immediately following terminate may cut off
                // notifications that have not yet left the process. Move
                // quitting to the next runloop turn.
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
    }
}

/// AppKit delegate. Divided by role:
///
///   - Main app: start Sparkle, ensure the agent is running, receive tray
///     commands;
///   - Agent: subscribe to the scan / clean state broadcast by the main
///     app, merging it into the panel snapshot.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Callback that rebuilds / focuses the main window.
    ///
    /// Installed by the main window root view when the scene is ready
    /// (see `MainWindowRootView.onAppear`): only an `openWindow` from
    /// within the scene can bring a closed window back up.
    /// Stored on a static property, so it remains valid after the main
    /// window closes.
    static var reopenMainWindow: (@MainActor () -> Void)?

    /// The current process's VM. Installed by the main window root view /
    /// the tray label respectively; the command handler and state
    /// subscription modify the VM accordingly.
    static var viewModel: AppViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Crash collection is armed here, before anything can crash and in
        // both roles — the tray agent is the same binary and dies on its
        // own. It reads the shared preference directly rather than going
        // through the view model: the VM is constructed by tests as freely
        // as by the app, and installing signal handlers as a construction
        // side effect would point the test runner's own crashes at our
        // writer. Pruning runs after arming because arming is what creates
        // the records directory.
        CrashCollector.applyStoredPreference()
        CrashLogStore.prune()

        if AppIdentity.currentProcessIsAgent {
            MackitLog.ui.info("tray agent started")
            // A resident process does not accept being terminated for
            // "looking idle": NSSupportsAutomaticTermination is turned off
            // in the plist, but testing shows processes launched via a
            // LaunchServices login item still get tagged with TAL, so
            // disable it programmatically once more.
            ProcessInfo.processInfo.disableAutomaticTermination("Mackit tray stays resident")
            // The main app broadcasts scan / clean state over, which is
            // merged into the panel snapshot's scan fields; the monitoring
            // fields (CPU / memory / temperature / rankings) are polled by
            // this process itself and are unaffected — the panel must keep
            // updating after the main app quits.
            AppBridge.observeScanState { state in
                Self.viewModel?.applyRemoteScanState(state)
            }
            // After the main app changes settings (monitoring toggles,
            // language, ...), re-read the shared settings so the panel and
            // menu bar labels catch up immediately, without waiting for an
            // agent restart.
            AppBridge.observeSettingsChanged {
                Self.viewModel?.reloadSettings()
                // The crash-collection switch takes effect in this process
                // too: the handlers were armed (or not) at launch, and a
                // change made in the main app has to reach the resident
                // agent without waiting for its next restart.
                CrashCollector.applyStoredPreference()
                // If the language selection has changed, this process's
                // resolved language cannot be changed, so restart the
                // whole process
                MackitEntry.relaunchIfLanguageChanged()
            }
        } else {
            // The updater is started only here: Sparkle requires the
            // startup timing to be no earlier than app launch completion,
            // and the controller must be strongly referenced
            // (UpdateController is a singleton, so that is satisfied).
            // In development builds with no feed configured,
            // startIfNeeded returns directly.
            UpdateController.shared.startIfNeeded()
            // The tray agent is a separate process embedded in this bundle:
            // after an update (or a reinstall over an older copy) the resident
            // one keeps running the previous build's code, leaving the menu
            // bar on the old version. Restart it first, so a launch that finds
            // no agent resident lets ensureAgentRunning below bring one up
            // from the current bundle.
            UpdateController.shared.restartTrayAgentIfBundleReplaced()
            // When the user launches the main app directly from the Dock /
            // Finder, the agent in the login items may not have been brought up
            // yet (or a login item was never registered). Bring it up once
            // more so the tray is immediately usable.
            AppBridge.ensureAgentRunning()
            // The login item registration caches a launch constraint from the
            // agent binary it was built from. A replaced binary — a rebuild, an
            // update, a reinstall — leaves that constraint stale, and the agent
            // is then killed at every login with a launch-constraint violation
            // while launchd removes the service: the menu bar icon simply never
            // appears. Rebuild the registration here, where the current binary
            // is on disk, instead of letting the user find out at the next
            // login. A no-op unless something actually needs rebuilding.
            Task {
                do {
                    try await LaunchAtLogin.repairIfNeeded(preferred: LaunchAtLogin.preferredIntent())
                } catch {
                    MackitLog.ui.error("rebuilding the launch-at-login registration failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            startAgentWatchdog()
            // Tray command channel.
            AppBridge.observeCommands { command, text, style in
                Self.handleCommand(command, text: text, style: style)
            }
        }
    }

    /// Agent watchdog: after the agent exits abnormally (crash, being
    /// killed by Activity Monitor) the tray icon is gone, and the user has
    /// to restart the main app to get it back — the login item only pulls
    /// it up at next login. While the main app is running, bring it up
    /// periodically once more, so this pair of processes self-heals.
    private func startAgentWatchdog() {
        // Does not hold self: the loop body only uses AppBridge's static
        // methods, so capturing it would be pointless, and writing it
        // would only earn a "written to, but never read" warning.
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                AppBridge.ensureAgentRunning()
            }
        }
    }

    /// Clicking the Dock icon: bring the main window back.
    ///
    /// After close-window-quits, normally "process is running" is
    /// equivalent to "window is open"; this callback can only be
    /// triggered within the short window between closing the window and
    /// quitting, and is kept as a fallback. The agent is LSUIElement and
    /// never receives reopen, so it ignores this directly.
    func applicationShouldHandleReopen(_ notification: Notification) -> Bool {
        guard !AppIdentity.currentProcessIsAgent else { return false }
        MackitLog.ui.info("reopen: focus main window")
        Self.reopen()
        return true
    }

    /// Quit when the last window closes — this is the reliable signal for
    /// "window closed".
    ///
    /// The traffic lights, ⌘W, and the "Close" menu item all go through
    /// AppKit's window-closing path, and this method is guaranteed to be
    /// asked when the last window closes. The scenePhase route is
    /// unreliable: after closing the window the app is still the frontmost
    /// app (still active even with no windows), so scenePhase does not
    /// fall to .background, and relying on it to quit would wait forever.
    /// ⌘H only hides without closing the window, so it does not reach
    /// here, and Dock reopening is unaffected.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard !AppIdentity.currentProcessIsAgent else { return false }
        MackitLog.ui.info("last window closed: quitting main app, tray agent stays resident")
        // The same move as the scenePhase route: broadcast the exit state
        // that keeps the total and zeroes the selection, so the tray panel
        // does not lose the last scan's result when the window closes
        // (see scanStateForExit). When the VM is not yet ready (the window
        // has never truly been shown) there is nothing to keep, so fall
        // back to all zeros.
        AppBridge.postScanState(Self.viewModel?.scanStateForExit() ?? ScanState())
        return true
    }

    /// Executes one tray command (only the main app role receives these).
    static func handleCommand(_ command: AppCommand, text: String? = nil, style: String? = nil) {
        guard let vm = viewModel else {
            MackitLog.ui.error("received command \(command.rawValue, privacy: .public) but VM is not ready")
            return
        }
        switch command {
        case .openMainWindow:
            reopen()
        case .settings:
            reopen()
            vm.showSettings()
        case .hardware:
            reopen()
            vm.showHardware()
        case .clean:
            reopen()
            vm.cleanFromRemote()
        case .quit:
            // First dismiss any pending sheets before quitting: sheets
            // like the confirmation dialog hang off the modal session, so
            // calling terminate directly gets stuck — testing showed that
            // clicking "Quit" in the tray with a sheet open did nothing,
            // and only worked after the sheet was dismissed. Dismiss it
            // with a cancel semantics so cleanup is not triggered by
            // mistake.
            for window in NSApp.windows {
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel)
                }
            }
            NSApp.terminate(nil)
        case .notice:
            // The result of an agent-side operation (e.g. free memory) is
            // passed through to the main window's Toast.
            guard let text else { return }
            vm.showToast(Banner.Style.from(wireName: style ?? "info"), text)
        }
    }

    /// Focus the main window: first bring the window up, then bring
    /// ourselves to the foreground.
    private static func reopen() {
        reopenMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}
