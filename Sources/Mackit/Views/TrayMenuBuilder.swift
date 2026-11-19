import Foundation

/// The right-click context menu's content, as pure data.
///
/// Split from the AppKit rendering in `TrayStatusController` so the menu's
/// structure — groups, checkmarks, enable states, which action each row
/// fires — is unit-testable without a status bar or a live NSMenu: the tests
/// construct a `TrayMenuState` and read the entries back.
///
/// The arrangement follows the menu-bar utility the product was modeled on:
/// app entry points, the tool pages, the display switches, updates / about,
/// and quit at the bottom, with separators between the groups.
enum TrayMenuRole: Equatable, Hashable {
    /// App entry points.
    case openMain
    case settings
    /// The cleaning action (runs directly; the tool pages below navigate).
    case clean
    /// The tool-page destinations, in sidebar order.
    case appUninstall
    case homebrew
    case largeFiles
    case duplicates
    case diskAnalysis
    case loginItems
    case hardware
    /// The three display switches, toggled in place.
    case toggleCPU
    case toggleMemory
    case toggleTemperature
    /// Updates / about / quit.
    case checkUpdates
    case about
    case quit
}

/// One row of the menu.
enum TrayMenuEntry: Equatable {
    case separator
    /// A plain command row. `enabled == false` grays the row out — used for
    /// "Check for Updates" in development builds without an update feed,
    /// matching how the main window's menu disables its own item.
    case action(role: TrayMenuRole, title: String, systemImage: String?, enabled: Bool)
    /// A checkmark row bound to one display switch; the label carries the
    /// same wording as the settings page's switch.
    case toggle(role: TrayMenuRole, title: String, isOn: Bool)
}

/// The inputs the menu depends on: the three display switches' current
/// states and whether an update feed exists.
struct TrayMenuState: Equatable {
    var updateEnabled: Bool
    var showCPU: Bool
    var showMemory: Bool
    var showTemperature: Bool
}

enum TrayMenuBuilder {
    /// Builds the menu rows for the given state.
    ///
    /// Titles come straight from the catalog; most keys are shared with the
    /// sidebar and the settings page, so a translation only ever needs to
    /// land in one place. The two tray-only keys (`menubar.openApp`,
    /// `menubar.about`) follow the `menubar.quit` convention of embedding
    /// the product name.
    static func entries(for state: TrayMenuState) -> [TrayMenuEntry] {
        [
            .action(role: .openMain, title: L10n.tr("menubar.openApp"), systemImage: nil, enabled: true),
            .action(role: .settings, title: L10n.tr("menubar.settings"), systemImage: "gearshape", enabled: true),
            .separator,
            .action(role: .clean, title: L10n.tr("panel.clean"), systemImage: "sparkles", enabled: true),
            .action(role: .appUninstall, title: L10n.tr("sidebar.appUninstall"), systemImage: "square.grid.2x2.fill", enabled: true),
            .action(role: .homebrew, title: L10n.tr("sidebar.homebrew"), systemImage: "shippingbox", enabled: true),
            .action(role: .largeFiles, title: L10n.tr("sidebar.largeFiles"), systemImage: "scalemass.fill", enabled: true),
            .action(role: .duplicates, title: L10n.tr("sidebar.duplicateFiles"), systemImage: "doc.on.doc", enabled: true),
            .action(role: .diskAnalysis, title: L10n.tr("sidebar.diskAnalysis"), systemImage: "chart.pie", enabled: true),
            .action(role: .loginItems, title: L10n.tr("sidebar.loginItems"), systemImage: "power", enabled: true),
            .action(role: .hardware, title: L10n.tr("hw.title"), systemImage: "cpu", enabled: true),
            .separator,
            .toggle(role: .toggleCPU, title: L10n.tr("settings.menubar.cpu"), isOn: state.showCPU),
            .toggle(role: .toggleMemory, title: L10n.tr("settings.menubar.memory"), isOn: state.showMemory),
            .toggle(role: .toggleTemperature, title: L10n.tr("settings.menubar.temperature"), isOn: state.showTemperature),
            .separator,
            .action(
                role: .checkUpdates,
                title: L10n.tr("menu.checkForUpdates"),
                systemImage: "arrow.triangle.2.circlepath",
                enabled: state.updateEnabled
            ),
            .action(role: .about, title: L10n.tr("menubar.about"), systemImage: "info.circle", enabled: true),
            .separator,
            .action(role: .quit, title: L10n.tr("menubar.quit"), systemImage: "rectangle.portrait.and.arrow.right", enabled: true),
        ]
    }
}
