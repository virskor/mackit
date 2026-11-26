import SwiftUI

/// Tray agent: a background process resident in the menu bar.
///
/// LSUIElement = 1 (accessory form, see the agent's Info.plist in
/// Scripts/build-app.sh): it never enters the Dock and has no windows. It
/// holds the menu bar icon, the panel, the right-click context menu and the
/// system monitoring polling; scan / clean / settings / hardware pages are
/// all in the main program, which is woken up by commands sent over via
/// `AppBridge`.
///
/// Why the split matters: closing the main window = the main process quits
/// = the Dock icon disappears, while the monitoring here never stops for a
/// minute. When the user clicks the tray icon, the agent brings the main
/// program up on demand.
///
/// The icon, its panel window and its context menu are AppKit-owned (see
/// `TrayStatusController`, created by `AppDelegate` at launch): SwiftUI's
/// `MenuBarExtra` cannot tell a left click from a right click — the same
/// window opens for either — and the product wants a right-click-only
/// native menu, so the status item has to belong to AppKit. This App shell
/// therefore only exists to satisfy the `App` protocol.
///
/// Shares the same binary as the main program, with the role distinguished
/// by bundle ID (see `MackitEntry`).
struct MackitAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The agent has no SwiftUI surface: an empty settings scene
        // satisfies the App protocol, and LSUIElement keeps it unreachable
        // (no menu opens it). Everything visible is built by the delegate.
        Settings { EmptyView() }
    }
}
