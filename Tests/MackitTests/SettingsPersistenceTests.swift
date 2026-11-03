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

    /// The appearance choice has to survive a relaunch and reach the tray
    /// agent, which re-reads the shared file on the settings-changed
    /// broadcast: a key that only existed on the write side would make the
    /// picker appear to work and then silently revert to following the
    /// system.
    @Test func appearanceRoundTripsThroughSharedSettings() {
        var saved: [String: Any] = [:]
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { saved = $0 }

        vm.appAppearance = .dark
        vm.saveSettings()

        #expect(saved["appAppearance"] as? String == "dark")

        let reread = AppViewModel(statsPolling: false)
        reread.loadSettings(from: saved)

        #expect(reread.appAppearance == .dark)
    }

    /// An absent key is a settings file written before the key existed, and
    /// a value the enum no longer knows has to land on `.system` rather
    /// than leaving the picker showing nothing selected.
    ///
    /// The choice is set first and asserted against that: a VM's own init
    /// reads the developer's live settings file, so asserting on a freshly
    /// constructed one would be testing that file — which, on a machine
    /// where a side was picked, fails for reasons that have nothing to do
    /// with the load path.
    @Test func appearanceFallsBackToSystemWhenUnreadable() {
        let vm = AppViewModel(statsPolling: false)
        vm.appAppearance = .dark

        // An absent key leaves the current choice alone; on a fresh process
        // that choice is the `.system` default, so an old file keeps
        // following the system rather than pinning a side.
        vm.loadSettings(from: [:])
        #expect(vm.appAppearance == .dark)

        vm.loadSettings(from: ["appAppearance": "highContrast"])
        #expect(vm.appAppearance == .system)
    }

    /// `.system` is the only choice that maps to no override — the other two
    /// are what gets installed on the process, and a `.system` that resolved
    /// to a concrete appearance would pin every user to one side.
    @Test func systemAppearanceMapsToNoAppKitOverride() {
        #expect(AppAppearance.system.nsAppearanceName == nil)
        #expect(AppAppearance.light.nsAppearanceName == .aqua)
        #expect(AppAppearance.dark.nsAppearanceName == .darkAqua)
    }

    /// The persisted project-root list is deduplicated on load. The array is
    /// written as-is, and a settings file that repeats a path — a hand edit, or
    /// an older writer — would put duplicate ids into the settings list's
    /// ForEach, which is undefined territory for row identity.
    @Test func duplicateProjectRootsAreDeduplicatedOnLoad() {
        let vm = AppViewModel(statsPolling: false)
        // The sink is redirected even though this test builds its
        // dictionary by hand: without the redirect, saveSettings would
        // write the developer's real shared settings file.
        vm.settingsSink = { _ in }
        vm.projectRoots = ["/Users/me/work", "/Users/me/play"]
        vm.saveSettings()

        let reread = AppViewModel(statsPolling: false)
        reread.loadSettings(from: [
            "projectRoots": ["/Users/me/work", "/Users/me/work", "/Users/me/play", "", "/Users/me/play"]
        ])

        #expect(reread.projectRoots == ["/Users/me/work", "/Users/me/play"], "duplicates and blanks survived the load: \(reread.projectRoots)")
    }

    /// The ignore list has to reach the shared file in both halves: a path
    /// entry and a rule entry that only lived in memory would come back
    /// after every relaunch.
    @Test func ignoreListIsPersisted() {
        var saved: [String: Any] = [:]
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { saved = $0 }
        vm.addIgnoredPath("/Users/me/Library/Caches/foo")
        vm.addIgnoredRule("browser.chrome-cache")

        let reread = AppViewModel(statsPolling: false)
        reread.loadSettings(from: saved)

        #expect(reread.ignoredPaths == ["/Users/me/Library/Caches/foo"])
        #expect(reread.ignoredRules == ["browser.chrome-cache"])
    }

    /// Deduplicated on load for the same reason as the project roots: both
    /// lists are ForEach'd by value in the settings pane, and a repeated row
    /// is undefined territory for row identity.
    @Test func duplicateIgnoreListEntriesAreDeduplicatedOnLoad() {
        let reread = AppViewModel(statsPolling: false)
        reread.loadSettings(from: [
            "ignoredPaths": ["/a", "/a", "", "/b"],
            "ignoredRules": ["xcode.docs", "xcode.docs", ""],
        ])

        #expect(reread.ignoredPaths == ["/a", "/b"])
        #expect(reread.ignoredRules == ["xcode.docs"])
    }

    /// The launch-at-login choice has to reach the shared file. The system
    /// registration can go stale on its own — a rebuild replaces the binary its
    /// launch constraint pins — and the persisted choice is what lets the app
    /// rebuild it at the next launch instead of silently dropping the user's
    /// request (which is what reading the system state directly did).
    @Test func launchAtLoginChoiceIsPersisted() {
        var saved: [String: Any] = [:]
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { saved = $0 }

        vm.launchAtLogin = true
        vm.saveSettings()

        #expect(saved["launchAtLogin"] as? Bool == true)

        let reread = AppViewModel(statsPolling: false)
        reread.loadSettings(from: saved)

        #expect(reread.launchAtLogin == true)
    }

    /// The crash-collection choice has to reach the shared file like every
    /// other setting, and applying it has to go through the injected seam —
    /// a test that flips the switch must not install signal handlers in the
    /// test runner itself.
    @Test func crashCollectionChoiceIsPersistedAndApplied() {
        var saved: [String: Any] = [:]
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { saved = $0 }
        var applied: [Bool] = []
        vm.crashCollectionApply = { applied.append($0) }

        vm.setCrashLogCollection(false)

        #expect(vm.collectCrashLogs == false)
        #expect(saved["collectCrashLogs"] as? Bool == false)
        #expect(applied == [false])

        let reread = AppViewModel(statsPolling: false)
        reread.loadSettings(from: saved)

        #expect(reread.collectCrashLogs == false)
    }

    /// Default on: a settings file written before the key existed (an
    /// upgrade) must not silently turn collection off.
    @Test func crashCollectionDefaultsOn() {
        let vm = AppViewModel(statsPolling: false)

        vm.loadSettings(from: [:])

        #expect(vm.collectCrashLogs == true)
    }
}
