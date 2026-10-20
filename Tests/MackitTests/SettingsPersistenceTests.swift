import Foundation
import Testing

@testable import Mackit

/// The settings the VM persists.
///
/// Every toggle the settings page exposes has to reach the shared file, or the
/// change is silently lost on the next launch — and, for the menu bar
/// switches, it never reaches the tray agent either, since the agent re-reads
/// the file on the settings-changed broadcast. The write side goes through
/// `settingsSink`, a seam that keeps the test off the developer's own settings.
@MainActor
struct SettingsPersistenceTests {
    /// The four menu bar switches all belong in the payload: the icon is a
    /// switch like the others, and a key that only exists on the read side
    /// would make the setting appear to work and then reset on relaunch.
    @Test func menuBarTogglesArePersisted() {
        let vm = AppViewModel(statsPolling: false)
        var saved: [String: Any] = [:]
        vm.settingsSink = { saved = $0 }

        vm.showMenuBarLogo = false
        vm.saveSettings()

        #expect(saved["showMenuBarLogo"] as? Bool == false)
        #expect(saved["showMenuBarCPU"] as? Bool == true)
        #expect(saved["showMenuBarMemory"] as? Bool == true)
        #expect(saved["showMenuBarTemperature"] as? Bool == true)
    }

    /// Reading back what was written is what makes the toggle survive a
    /// relaunch: the keys on both sides have to be the same literal.
    @Test func persistedMenuBarTogglesRoundTrip() {
        var saved: [String: Any] = [:]
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { saved = $0 }

        vm.showMenuBarLogo = false
        vm.saveSettings()

        let reread = AppViewModel(statsPolling: false)
        reread.loadSettings(from: saved)

        #expect(reread.showMenuBarLogo == false)
    }
}
