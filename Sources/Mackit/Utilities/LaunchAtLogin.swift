import Foundation
import ServiceManagement

/// Launch at login: registers the bundled tray agent (`SMAppService.loginItem`).
///
/// Under the split architecture, what lives in the menu bar is the agent, so the login
/// item points to it rather than the main program: at login only the menu bar icon
/// appears, and the main window does not pop up—the main window is opened by the user
/// clicking the tray. The agent must reside in the main program's
/// `Contents/Library/LoginItems/MackitAgent.app` (assembled by Scripts/build-app.sh);
/// running the executable directly from `.build` will fail registration, which is
/// expected.
enum LaunchAtLogin {
    /// Whether launch at login is currently registered. Manual changes made by the user
    /// in "System Settings › General › Login Items" are reflected here as well.
    static var isEnabled: Bool {
        SMAppService.loginItem(identifier: AppIdentity.agentBundleID).status == .enabled
    }

    static func register() throws {
        try SMAppService.loginItem(identifier: AppIdentity.agentBundleID).register()
    }

    static func unregister() async throws {
        try await SMAppService.loginItem(identifier: AppIdentity.agentBundleID).unregister()
    }
}
