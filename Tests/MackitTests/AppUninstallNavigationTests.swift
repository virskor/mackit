import Foundation
import Testing

@testable import Mackit

/// The contract between the app uninstall tool page and the app's navigation.
///
/// The page is a sidebar destination the user flips through, while the scan
/// behind it walks /Applications and ~/Library. These tests pin the contract
/// from the view model's side: no sidebar route may discard the scanned app
/// list (the same rule the disk analysis measurement and the Homebrew
/// snapshot follow), and every route out must clear the page's flag so the
/// detail area follows the selection.
///
/// The model is fixture-backed, so nothing here touches a real /Applications.
@MainActor
struct AppUninstallNavigationTests {
    private func makeModel(counters: LoadCounter = LoadCounter()) -> (AppUninstallModel, LoadCounter) {
        let model = AppUninstallModel(
            scan: {
                counters.scans += 1
                return []
            }
        )
        return (model, counters)
    }

    private final class LoadCounter: @unchecked Sendable {
        var scans = 0
    }

    @Test func openingTheToolClearsEverySiblingPage() {
        let (model, _) = makeModel()
        let vm = AppViewModel(statsPolling: false, appUninstall: model)

        vm.showSettings()
        vm.showAppUninstall()

        #expect(vm.showsAppUninstall)
        #expect(!vm.showsSettings)
        #expect(!vm.showsHardware)
        #expect(!vm.showsGeneralCleanup)
        #expect(!vm.showsDiskAnalysis)
        #expect(!vm.showsHomebrew)
        #expect(vm.selectedCategory == nil, "the tool is not a category filter")
    }

    @Test func firstEntryScansOnce() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, appUninstall: model)

        vm.showAppUninstall()
        await model.waitUntilSettled()
        #expect(counters.scans == 1)

        // Leaving and coming back must not re-scan.
        vm.showSettings()
        vm.showAppUninstall()
        await model.waitUntilSettled()
        #expect(counters.scans == 1)
    }

    @Test func everyRouteOutOfTheToolClearsItsFlag() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, appUninstall: model)

        vm.showAppUninstall()
        await model.waitUntilSettled()
        #expect(counters.scans == 1)

        // Every sibling route clears the tool's flag. The hardware page is
        // in the list on purpose: it samples the machine on entry, which is
        // exactly the kind of side effect a page-switch contract should not
        // depend on.
        vm.showGeneralCleanup()
        #expect(!vm.showsAppUninstall)

        vm.showAppUninstall()
        vm.showDiskAnalysis()
        #expect(!vm.showsAppUninstall)
        #expect(vm.showsDiskAnalysis)

        vm.showAppUninstall()
        vm.showHomebrew()
        #expect(!vm.showsAppUninstall)
        #expect(vm.showsHomebrew)

        vm.showAppUninstall()
        vm.showHardware()
        #expect(!vm.showsAppUninstall)

        vm.showAppUninstall()
        vm.selectCategory(nil)
        #expect(!vm.showsAppUninstall)

        // None of the routes discarded the scanned list.
        #expect(counters.scans == 1)
    }
}
