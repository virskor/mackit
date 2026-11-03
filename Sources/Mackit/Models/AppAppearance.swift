import AppKit

/// Which appearance the interface runs in.
///
/// The default is `.system`: the app follows macOS like every other window,
/// and only a user who wants otherwise picks a side. `.light` and `.dark`
/// are applied by installing an `NSAppearance` on the process (see `apply`),
/// which overrides the system for this app's own windows only — the rest of
/// the desktop keeps whatever the system is set to, and the System Settings
/// picker the user already knows still governs everything else.
///
/// Unlike the language selection this needs no process restart: an
/// appearance is a per-window decision AppKit re-evaluates, so the choice
/// lands on the main window, the tray panel and every sheet the moment it
/// is picked.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    /// Follow the system appearance.
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The AppKit appearance this choice installs, or `nil` to follow the
    /// system.
    ///
    /// Why AppKit and not SwiftUI's `preferredColorScheme`: that modifier
    /// only ever *sets* an appearance on the hosting window, and handing it
    /// `nil` back does not clear what it set — a window that was pinned
    /// dark stays dark after the user picks "auto", which is precisely the
    /// state that modifier documents as "follow the system". `NSApp.appearance`
    /// is the same switch one level up, and assigning `nil` to it does
    /// remove the override, which is what makes "auto" reachable again.
    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    /// Installs this choice as this process's appearance.
    ///
    /// App-wide rather than per-window on purpose: the main window, its
    /// sheets and the tray agent's panel are separate windows, and in the
    /// agent's case a separate process, so they all have to agree.
    @MainActor
    func apply() {
        // flatMap, not map: `NSAppearance(named:)` is imported from the
        // nullable `appearanceNamed:`, so it already answers an optional —
        // and the two names this maps to are the built-in ones, which the
        // SDK documents as always present. A name it did not know would
        // land on nil, which is the `.system` behavior, not a crash.
        NSApp.appearance = nsAppearanceName.flatMap { NSAppearance(named: $0) }
    }

    /// The choice recorded in shared settings; `.system` when nothing has
    /// been recorded (or the value is unreadable).
    ///
    /// Read straight from the file rather than through a view model because
    /// it is needed before one exists: the appearance has to be in place by
    /// the time the first window is drawn, which is earlier than
    /// `applicationDidFinishLaunching`'s view-model install. Main-actor
    /// isolated for the same reason `SharedStore` is.
    @MainActor
    static func stored() -> AppAppearance {
        AppAppearance(rawValue: SharedStore.loadSettings()["appAppearance"] as? String ?? "") ?? .system
    }

    /// The settings picker's label for this choice.
    var displayName: String {
        switch self {
        case .system: return L10n.tr("settings.appearance.system")
        case .light: return L10n.tr("settings.appearance.light")
        case .dark: return L10n.tr("settings.appearance.dark")
        }
    }
}
