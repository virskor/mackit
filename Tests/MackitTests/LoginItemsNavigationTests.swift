import Foundation
import Testing

@testable import Mackit

/// The contract between the startup-items tool page and the app's
/// navigation, pinned from the view model's side the same way the other
/// tools' navigation tests are: every route out clears the page's flag,
/// and no sibling route discards a scanned list.
///
/// The model is fixture-backed, so nothing here touches a real launchd.
@MainActor
struct LoginItemsNavigationTests {
    /// Counts the model's activations, so "entering the page activates
    /// the model once" is an assertion about the count rather than
    /// about a flag a double call could not have changed anyway.
    private final class ActivationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func bump() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private func makeModel(items: [LoginItem] = [], counter: ActivationCounter? = nil) -> LoginItemsModel {
        LoginItemsModel(
            scan: {
                counter?.bump()
                return items
            },
            apply: { _, _ in .success },
            readHelperState: { .notInstalled },
            installHelper: { .succeeded },
            uninstallHelper: { .success },
            appVersion: "1.2.3",
            iconForPath: { _ in nil }
        )
    }

    @Test func openingTheToolClearsEverySiblingPage() {
        let vm = AppViewModel(statsPolling: false, loginItems: makeModel())

        vm.showSettings()
        vm.showHomebrew()
        vm.showLoginItems()

        #expect(vm.showsLoginItems)
        #expect(!vm.showsSettings)
        #expect(!vm.showsHardware)
        #expect(!vm.showsGeneralCleanup)
        #expect(!vm.showsDiskAnalysis)
        #expect(!vm.showsHomebrew)
        #expect(!vm.showsAppUninstall)
        #expect(!vm.showsLargeFiles)
    }

    @Test func everySiblingRouteClearsThePage() {
        let vm = AppViewModel(statsPolling: false, loginItems: makeModel())

        vm.showLoginItems()
        #expect(vm.showsLoginItems)

        vm.showHardware()
        #expect(!vm.showsLoginItems)

        vm.showLoginItems()
        vm.showSettings()
        #expect(!vm.showsLoginItems)

        vm.showLoginItems()
        vm.showDiskAnalysis()
        #expect(!vm.showsLoginItems)

        vm.showLoginItems()
        vm.showHomebrew()
        #expect(!vm.showsLoginItems)

        vm.showLoginItems()
        vm.showAppUninstall()
        #expect(!vm.showsLoginItems)

        vm.showLoginItems()
        vm.showLargeFiles()
        #expect(!vm.showsLoginItems)

        vm.showLoginItems()
        vm.showGeneralCleanup()
        #expect(!vm.showsLoginItems)

        // A category row returns to the item list, like every other page.
        vm.showLoginItems()
        vm.selectCategory(nil)
        #expect(!vm.showsLoginItems)
    }

    @Test func theScannedListSurvivesPageSwitches() async {
        let items = [
            LoginItem(
                id: "/Users/x/Library/LaunchAgents/com.a.plist",
                kind: .userAgent,
                label: "com.a",
                plistPath: "/Users/x/Library/LaunchAgents/com.a.plist",
                targetPath: nil,
                app: nil,
                isEnabled: true
            )
        ]
        let vm = AppViewModel(statsPolling: false, loginItems: makeModel(items: items))

        vm.showLoginItems()
        await vm.loginItems.waitUntilSettled()
        #expect(vm.loginItems.hasScanned)

        // Leaving and coming back is instant — the scan belongs to the
        // session, not to the page being visible.
        vm.showHardware()
        vm.showLoginItems()
        #expect(vm.loginItems.hasScanned)
        #expect(vm.loginItems.items.count == 1)
    }

    @Test func enteringThePageActivatesTheModelOnce() async {
        let counter = ActivationCounter()
        let vm = AppViewModel(statsPolling: false, loginItems: makeModel(counter: counter))

        // A second call to an already-active route does nothing.
        vm.showLoginItems()
        vm.showLoginItems()
        #expect(vm.showsLoginItems)
        await vm.loginItems.waitUntilSettled()
        #expect(counter.value == 1, "entering the page activates the model once, not per call")
    }
}
