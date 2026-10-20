import Foundation
import AppKit

/// The identities of the two processes.
enum AppIdentity {
    /// The main program's bundle ID.
    static let mainBundleID = "cn.mingcui.mackit"
    /// The tray agent's bundle ID. Consistent with MackitAgent.app's
    /// Info.plist.
    static let agentBundleID = "cn.mingcui.mackit.agent"

    /// Whether the current process is the tray agent. The same binary is
    /// installed in two bundles, with the role distinguished by bundle ID.
    static var currentProcessIsAgent: Bool {
        Bundle.main.bundleIdentifier == agentBundleID
    }
}

/// Commands sent from the agent to the main program.
///
/// Every "move the main window" action on the tray panel ultimately
/// becomes a command: the agent itself only holds the monitoring and the
/// panel; scanning, cleaning, settings and the hardware page are all on
/// the main program's side.
enum AppCommand: String {
    /// Open / focus the main window.
    case openMainWindow
    /// Open the main window and show the settings page.
    case settings
    /// Open the main window and show the hardware page.
    case hardware
    /// Open the main window and go straight to clean confirmation (select
    /// all safe items, then pop up the confirmation panel).
    case clean
    /// Quit the main program (the agent then quits on its own).
    case quit
    /// Have the main program pop a Toast; the text is in the payload,
    /// used to feed results of agent-side operations (such as freeing
    /// memory) back to an already-open main window.
    case notice
}

/// Main program → agent scan / clean state synchronization.
///
/// The tray panel's header card must display "reclaimable size" and the
/// selection count; these data exist only in the main program's VM.
/// Monitoring data (CPU / memory / temperature / rankings) is in turn
/// polled only by the agent itself—it must keep ticking even after the
/// main program quits, so each side holds its own; what is synchronized
/// here is only the scan and clean half.
struct ScanState: Codable, Equatable {
    /// The rawValue of `AppViewModel.ScanPhase`; defaults to idle.
    var phase: String = "idle"
    /// The rawValue of `AppViewModel.CleanPhase`.
    var cleanPhase: String = "idle"
    /// Scan progress percentage, 0–100.
    var percent: Int = 0
    var totalSize: Int64 = 0
    var itemCount: Int = 0
    var selectedCount: Int = 0
    var selectedSize: Int64 = 0
}

/// The command and state channel between the agent and the main program.
///
/// Uses distributed notifications rather than XPC: commands are only
/// one-liners like "open window" and "quit", with small-dictionary
/// payloads; XPC's connection management and interface version
/// negotiation are pure overhead at this scale. (Tencent Lemon's
/// LemonMonitor binary likewise shows only traces of
/// DistributedNotificationCenter, no XPC.)
///
/// State that needs to survive across launches (settings, pending
/// commands) goes through shared files; see `SharedStore`.
@MainActor
enum AppBridge {
    /// agent → main program.
    static let commandNotification = Notification.Name("cn.mingcui.mackit.command")
    /// main program → agent.
    static let scanStateNotification = Notification.Name("cn.mingcui.mackit.scanState")
    /// main program → agent: settings were changed; the agent should
    /// re-read the shared settings.
    static let settingsChangedNotification = Notification.Name("cn.mingcui.mackit.settingsChanged")

    /// Observer tokens. The distributed notification center does not
    /// weakly reference block observers, so tokens must be held by the
    /// caller, otherwise the callbacks may be disposed of at any time.
    private static var commandObservers: [any NSObjectProtocol] = []
    private static var scanStateObservers: [any NSObjectProtocol] = []
    private static var settingsObservers: [any NSObjectProtocol] = []

    // MARK: - agent → main program

    /// Sends a command. When the main program is not running, all commands
    /// except quit / notice are first written to disk and then wake up the
    /// main program, relying on cold-start compensation to read them.
    static func send(_ command: AppCommand, text: String? = nil, style: String? = nil) {
        switch command {
        case .quit, .notice:
            // These two commands have no meaning of "launch the main
            // program and then execute": quit has nothing to do when the
            // main program is not running, and notice merely passes a
            // message to an already-open window.
            post(command, text: text, style: style)

        case .openMainWindow, .settings, .hardware, .clean:
            if isMainAppRunning() {
                post(command, text: text, style: style)
            } else {
                PendingCommandStore.write(command)
                launchMainApp()
            }
        }
    }

    /// Reads and takes the pending command after a cold start. Returns nil
    /// when there is nothing pending.
    static func takePendingCommand() -> AppCommand? {
        PendingCommandStore.take()
    }

    /// Subscribe to commands. The callback is guaranteed to run on the
    /// main thread.
    static func observeCommands(
        _ handler: @escaping @MainActor (AppCommand, String?, String?) -> Void
    ) {
        let token = DistributedNotificationCenter.default.addObserver(
            forName: commandNotification, object: nil, queue: .main
        ) { note in
            // The userInfo dictionary is not Sendable and cannot be taken
            // whole into a @MainActor closure; extract the values as
            // String inside the observer before entering the isolation
            // domain.
            let info = note.userInfo
            let raw = info?["command"] as? String
            let text = info?["text"] as? String
            let style = info?["style"] as? String
            guard let raw, let command = AppCommand(rawValue: raw) else { return }
            MainActor.assumeIsolated { handler(command, text, style) }
        }
        commandObservers.append(token)
    }

    // MARK: - main program → agent

    /// Broadcasts the scan / clean state.
    static func postScanState(_ state: ScanState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        DistributedNotificationCenter.default.post(
            name: scanStateNotification,
            object: nil,
            userInfo: ["state": data]
        )
    }

    /// Subscribe to scan state.
    static func observeScanState(_ handler: @escaping @MainActor (ScanState) -> Void) {
        let token = DistributedNotificationCenter.default.addObserver(
            forName: scanStateNotification, object: nil, queue: .main
        ) { note in
            // Same as above: Data is Sendable, the dictionary is not; take
            // it out first before entering the isolation domain.
            let data = note.userInfo?["state"] as? Data
            guard let data, let state = try? JSONDecoder().decode(ScanState.self, from: data) else { return }
            MainActor.assumeIsolated { handler(state) }
        }
        scanStateObservers.append(token)
    }

    /// Broadcast after the main program finishes writing the shared
    /// settings, so the agent reads them again.
    static func postSettingsChanged() {
        DistributedNotificationCenter.default.post(name: settingsChangedNotification, object: nil)
    }

    /// Subscribe to settings changes.
    static func observeSettingsChanged(_ handler: @escaping @MainActor () -> Void) {
        let token = DistributedNotificationCenter.default.addObserver(
            forName: settingsChangedNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        settingsObservers.append(token)
    }

    // MARK: - Internals

    private static func post(_ command: AppCommand, text: String?, style: String?) {
        var info: [String: String] = ["command": command.rawValue]
        if let text { info["text"] = text }
        if let style { info["style"] = style }
        DistributedNotificationCenter.default.post(name: commandNotification, object: nil, userInfo: info)
    }

    /// Whether the main program is currently running.
    static func isMainAppRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.mainBundleID).isEmpty
    }

    /// Wakes up the main program from the agent process.
    ///
    /// The agent is embedded in the main program's
    /// `Contents/Library/LoginItems`, with the main program four levels up
    /// the bundle path: MackitAgent.app → LoginItems → Library →
    /// Contents → Mackit.app.
    static func launchMainApp() {
        let mainAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: mainAppURL, configuration: .init())
    }

    /// Ensures the agent is running from within the main program process.
    ///
    /// When the user launches the main program directly from the Dock /
    /// Finder, the agent in the login items may not have been brought up
    /// yet (or was never registered as a login item). Bringing it up once
    /// more here makes the tray icon available immediately. If the agent
    /// is already running, do nothing.
    static func ensureAgentRunning() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.agentBundleID).isEmpty else {
            return
        }
        let agentURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/MackitAgent.app")
        guard FileManager.default.fileExists(atPath: agentURL.path) else {
            // Running the executable in .build directly (not assembled
            // into a .app) means there is no embedded agent, which is
            // expected; just log it.
            MackitLog.ui.info("embedded agent not found, skipping launch")
            return
        }
        MackitLog.ui.info("launching tray agent")
        NSWorkspace.shared.openApplication(at: agentURL, configuration: .init())
    }

    /// Restarts the resident tray agent so it runs the binary embedded in the
    /// current app bundle.
    ///
    /// The agent is a separate process whose bundle lives inside the main app
    /// bundle (Contents/Library/LoginItems). When the main app is updated —
    /// by Sparkle, or by reinstalling a newer copy over an older one — the
    /// embedded agent on disk is replaced along with it, but an agent that is
    /// already resident keeps executing the code it was started with. The
    /// menu bar then keeps showing the previous version's panel and labels
    /// until the next login. Terminating and relaunching it from the fresh
    /// bundle closes that gap.
    static func restartTrayAgent() {
        let agentURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/MackitAgent.app")
        guard FileManager.default.fileExists(atPath: agentURL.path) else {
            // Running the executable in .build directly (not assembled
            // into a .app) means there is no embedded agent, which is
            // expected; just log it.
            MackitLog.ui.info("embedded agent not found, skipping restart")
            return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.agentBundleID)
        // Nothing resident means nothing to refresh; the caller's
        // ensureAgentRunning brings the agent up from the current bundle.
        guard !running.isEmpty else { return }
        MackitLog.ui.info("restarting tray agent to run the updated bundle")
        for app in running {
            app.terminate()
        }
        // The relaunch runs in a detached shell rather than in this process:
        // the main app can die at any moment — it quits when its window
        // closes, and the dev script pkills it between builds — and an
        // in-process task would die with it, after the old agent has already
        // been asked to quit, leaving the menu bar empty until the next
        // login. The shell waits for the old agent to actually exit before
        // opening the fresh bundle: a new instance exits at startup while
        // another instance of its bundle ID is still alive (see
        // MackitEntry.main). Whatever survives the grace period is
        // force-killed — the agent's only persisted state is the overlay
        // position, which falls back to its default when its file is
        // truncated. Matching by executable name rather than pid: a recycled
        // pid must not be mistaken for the agent that was just asked to quit.
        let escaped = agentURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", """
        i=0
        while [ $i -lt 30 ] && pgrep -x MackitAgent > /dev/null; do
            sleep 0.1
            i=$((i + 1))
        done
        pkill -9 -x MackitAgent
        open '\(escaped)'
        """]
        try? relaunch.run()
    }

    /// Whether another agent instance with the same bundle ID is already
    /// running.
    ///
    /// The scenario that needs it: when the user turns on "launch at
    /// login" in settings, launchd immediately brings up the agent at the
    /// same moment the login item is registered—while the main program
    /// had already brought one up earlier (`ensureAgentRunning`), so the
    /// two processes each create a menu bar icon until the next login.
    /// Only one instance per bundle ID is allowed; a later-started one
    /// yields when it sees a predecessor.
    static func hasOtherAgentInstance() -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.agentBundleID)
            .contains { $0.processIdentifier != pid }
    }
}
