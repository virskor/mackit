import Foundation
import Testing

@testable import Mackit

/// The tray right-click menu's structure and the display-switch toggles it
/// writes.
///
/// The menu is split from the AppKit rendering (see `TrayMenuBuilder`)
/// exactly so this contract — groups, checkmarks, enable states, which
/// action each row fires — can be pinned without a status bar or a live
/// NSMenu.
@MainActor
struct TrayMenuTests {
    private func entries(
        updateEnabled: Bool = true,
        cpu: Bool = true,
        memory: Bool = true,
        temperature: Bool = true,
        overlay: Bool = false
    ) -> [TrayMenuEntry] {
        TrayMenuBuilder.entries(for: TrayMenuState(
            updateEnabled: updateEnabled,
            showCPU: cpu,
            showMemory: memory,
            showTemperature: temperature,
            showOverlay: overlay
        ))
    }

    /// The group layout: open / settings · tools · display switches ·
    /// updates / about · quit, in that order.
    @Test func groupsAreSeparatedInTheReferenceOrder() {
        let list = entries()

        #expect(list.filter { $0 == .separator }.count == 4)

        guard case let .action(openRole, _, _, _) = list.first else {
            Issue.record("first entry must be an action")
            return
        }
        #expect(openRole == .openMain)

        guard case let .action(quitRole, _, _, _) = list.last else {
            Issue.record("last entry must be an action")
            return
        }
        #expect(quitRole == .quit)

        // The tool rows sit between the settings row and the switches; each
        // destination the sidebar offers as a tool page has a row.
        let roles = list.compactMap { entry -> TrayMenuRole? in
            switch entry {
            case .separator: return nil
            case let .action(role, _, _, _): return role
            case let .toggle(role, _, _): return role
            }
        }
        let toolRows: [TrayMenuRole] = [
            .clean, .appUninstall, .homebrew, .largeFiles,
            .duplicates, .diskAnalysis, .loginItems, .hardware,
        ]
        for tool in toolRows {
            #expect(roles.contains(tool), "missing tool row \(tool)")
        }
    }

    /// Every row's title resolves from the catalog — not the raw key — with
    /// the shared wording of the settings page / sidebar / main menu.
    @Test func titlesResolveFromTheCatalog() {
        let list = entries()
        var titles: [TrayMenuRole: String] = [:]
        for entry in list {
            switch entry {
            case .separator:
                continue
            case let .action(role, title, _, _):
                titles[role] = title
            case let .toggle(role, title, _):
                titles[role] = title
            }
        }

        let expected: [(TrayMenuRole, String)] = [
            (.openMain, "menubar.openApp"),
            (.settings, "menubar.settings"),
            (.clean, "panel.clean"),
            (.appUninstall, "sidebar.appUninstall"),
            (.homebrew, "sidebar.homebrew"),
            (.largeFiles, "sidebar.largeFiles"),
            (.duplicates, "sidebar.duplicateFiles"),
            (.diskAnalysis, "sidebar.diskAnalysis"),
            (.loginItems, "sidebar.loginItems"),
            (.hardware, "hw.title"),
            (.toggleCPU, "settings.menubar.cpu"),
            (.toggleMemory, "settings.menubar.memory"),
            (.toggleTemperature, "settings.menubar.temperature"),
            (.toggleOverlay, "settings.overlay.show"),
            (.checkUpdates, "menu.checkForUpdates"),
            (.about, "menubar.about"),
            (.quit, "menubar.quit"),
        ]
        for (role, key) in expected {
            #expect(titles[role] == L10n.tr(key), "title for \(role) must come from \(key)")
            // The lookup actually hit the catalog instead of degrading to
            // the key itself.
            #expect(titles[role] != key, "\(key) is missing from the catalog")
        }
    }

    /// The four display switches are checkmarked per their current state.
    @Test func togglesReflectTheSwitchStates() {
        let list = entries(cpu: true, memory: false, temperature: true, overlay: false)

        func isOn(_ role: TrayMenuRole) -> Bool? {
            for entry in list {
                if case let .toggle(rowRole, _, isOn) = entry, rowRole == role {
                    return isOn
                }
            }
            return nil
        }

        #expect(isOn(.toggleCPU) == true)
        #expect(isOn(.toggleMemory) == false)
        #expect(isOn(.toggleTemperature) == true)
        #expect(isOn(.toggleOverlay) == false)
    }

    /// Without an update feed (a development build) the "Check for Updates"
    /// row is disabled, matching the main window's own menu item; with a
    /// feed it is enabled.
    @Test func checkUpdatesIsDisabledWithoutAFeed() {
        func checkUpdatesEnabled(in list: [TrayMenuEntry]) -> Bool? {
            for entry in list {
                if case let .action(.checkUpdates, _, _, enabled) = entry {
                    return enabled
                }
            }
            return nil
        }

        #expect(checkUpdatesEnabled(in: entries(updateEnabled: false)) == false)
        #expect(checkUpdatesEnabled(in: entries(updateEnabled: true)) == true)
    }

    /// Toggling from the menu flips the switch and persists it through the
    /// settings sink — the same write path the settings page uses.
    @Test func togglingADisplaySwitchFlipsAndPersists() {
        let vm = AppViewModel(statsPolling: false)
        vm.showMenuBarCPU = true
        var written: [[String: Any]] = []
        vm.settingsSink = { written.append($0) }

        vm.toggleTrayDisplay(.cpu)

        #expect(vm.showMenuBarCPU == false)
        #expect(written.count == 1)
        #expect(written.last?["showMenuBarCPU"] as? Bool == false)
    }

    /// All four switches flip independently.
    @Test func everyDisplaySwitchToggles() {
        let vm = AppViewModel(statsPolling: false)
        vm.showMenuBarCPU = false
        vm.showMenuBarMemory = false
        vm.showMenuBarTemperature = false
        vm.showDesktopStats = false
        vm.settingsSink = { _ in }

        vm.toggleTrayDisplay(.cpu)
        vm.toggleTrayDisplay(.memory)
        vm.toggleTrayDisplay(.temperature)
        vm.toggleTrayDisplay(.desktopOverlay)

        #expect(vm.showMenuBarCPU)
        #expect(vm.showMenuBarMemory)
        #expect(vm.showMenuBarTemperature)
        #expect(vm.showDesktopStats)
    }

    /// With no status-item controller attached (the main app, and every
    /// test process) the panel counts as invisible: the sampling guard
    /// skips when all switches are off.
    @Test func panelIsInvisibleWithoutAController() {
        let vm = AppViewModel(statsPolling: false)
        vm.showMenuBarCPU = false
        vm.showMenuBarMemory = false
        vm.showMenuBarTemperature = false

        #expect(TrayStatusController.current == nil)
        vm.sampleSystemStats()
        #expect(vm.menuSnapshot.stats.memoryTotal == 0)
    }
}
