import Foundation
import Testing

@testable import Mackit

/// The contract between the Homebrew tool page and the app's navigation.
///
/// The page is a sidebar destination the user flips through, while the
/// queries behind it are real subprocesses. These tests pin the corrected
/// contract from the view model's side: no sidebar route may discard a
/// loaded snapshot (the same rule the disk analysis measurement follows),
/// and every route out must clear the page's flag so the detail area
/// follows the selection.
///
/// The model is fixture-backed, so nothing here touches a real Homebrew.
@MainActor
struct HomebrewNavigationTests {
    private func makeModel(counters: LoadCounter = LoadCounter()) -> (HomebrewModel, LoadCounter) {
        let model = HomebrewModel(
            inspect: {
                counters.inspect += 1
                return nil
            },
            loadServices: {
                counters.services += 1
                return []
            },
            loadDiagnostics: {
                counters.diagnostics += 1
                return "output"
            },
            loadConfig: {
                counters.config += 1
                return []
            },
            perform: { _ in
                HomebrewOutcome(action: .cleanup, measure: 0, failure: nil)
            }
        )
        return (model, counters)
    }

    private final class LoadCounter: @unchecked Sendable {
        var inspect = 0
        var services = 0
        var diagnostics = 0
        var config = 0
    }

    @Test func openingTheToolClearsEverySiblingPage() {
        let (model, _) = makeModel()
        let vm = AppViewModel(statsPolling: false, homebrew: model)

        vm.showSettings()
        vm.showHomebrew()

        #expect(vm.showsHomebrew)
        #expect(!vm.showsSettings)
        #expect(!vm.showsHardware)
        #expect(!vm.showsGeneralCleanup)
        #expect(!vm.showsDiskAnalysis)
        #expect(vm.selectedCategory == nil, "the tool is not a category filter")
    }

    @Test func firstEntryLoadsOnce() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, homebrew: model)

        vm.showHomebrew()
        await model.waitUntilSettled()
        #expect(counters.inspect == 1)

        // Leaving and coming back must not re-query.
        vm.showSettings()
        vm.showHomebrew()
        await model.waitUntilSettled()
        #expect(counters.inspect == 1)
    }

    @Test func everyRouteOutOfTheToolClearsItsFlag() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, homebrew: model)

        vm.showHomebrew()
        await model.waitUntilSettled()
        #expect(counters.inspect == 1)

        // The hardware page samples GPU, battery and display state on entry,
        // so the general module stands in for "another module" — a
        // page-switch contract has no business depending on the machine
        // having that hardware.
        vm.showGeneralCleanup()
        #expect(!vm.showsHomebrew)

        vm.showHomebrew()
        vm.showDiskAnalysis()
        #expect(!vm.showsHomebrew)
        #expect(vm.showsDiskAnalysis)

        vm.showHomebrew()
        vm.selectCategory(nil)
        #expect(!vm.showsHomebrew)

        // None of the routes discarded the loaded state.
        #expect(counters.inspect == 1)
    }

    @Test func leavingTheToolKeepsItsSectionDataLoaded() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, homebrew: model)

        vm.showHomebrew()
        await model.waitUntilSettled()
        model.showSection(.services)
        await model.waitUntilSettled()
        #expect(counters.services == 1)

        vm.showSettings()
        vm.showHomebrew()
        await model.waitUntilSettled()

        #expect(model.section == .services, "the section selection survives the page switch")
        #expect(counters.services == 1, "a loaded section is not re-queried on return")
    }
}
