import Foundation
import Testing

@testable import Mackit

/// Verifies the safety property that cleaning must go through a list confirmation first.
@MainActor
struct CleanConfirmationTests {
    /// Build a view model with only a selection and no items, just enough to
    /// drive the state machine without touching the real file system.
    private func makeVM(selected: Set<String> = ["item-a", "item-b"]) -> AppViewModel {
        let vm = AppViewModel(statsPolling: false)
        vm.selection = selected
        return vm
    }

    @Test func requestCleanEntersConfirmingWithoutCleaning() async {
        let vm = makeVM()
        vm.requestClean()

        #expect(vm.cleanPhase == .confirming)
        // Key point: entering the confirming state must not mean cleaning has already started
        #expect(vm.cleanOutcomes.isEmpty)
        #expect(vm.lastReclaimed == 0)
    }

    @Test func requestCleanWithNoSelectionDoesNothing() async {
        let vm = makeVM(selected: [])
        vm.requestClean()
        #expect(vm.cleanPhase == .idle)
    }

    @Test func cancelConfirmationReturnsToIdle() async {
        let vm = makeVM()
        vm.requestClean()
        vm.cancelConfirmation()
        #expect(vm.cleanPhase == .idle)
    }

    /// Regression test: requesting again after a cancel must still enter the
    /// confirming state. The old implementation drove the panel with @State +
    /// onChange; after a cancel cleanPhase was still .confirming, so on the
    /// next click the value had not changed and onChange did not fire, and the
    /// panel no longer popped up.
    @Test func requestingAgainAfterCancelStillConfirms() async {
        let vm = makeVM()
        vm.requestClean()
        vm.cancelConfirmation()
        vm.requestClean()
        #expect(vm.cleanPhase == .confirming)
    }

    /// Across many cancel/request cycles, the confirming state must always be reachable.
    @Test func confirmationIsReachableAcrossManyCycles() async {
        let vm = makeVM()
        for _ in 0..<5 {
            vm.requestClean()
            #expect(vm.cleanPhase == .confirming)
            vm.cancelConfirmation()
            #expect(vm.cleanPhase == .idle)
        }
    }

    /// beginClean can only be called from the confirmation panel; once it executes, the state should immediately switch to cleaning.
    @Test func beginCleanTransitionsToCleaning() async {
        let vm = makeVM()
        vm.beginClean()
        #expect(vm.cleanPhase == .cleaning)
    }

    /// When the clean results page occupies the detail area, clicking a
    /// sidebar category row must dismiss it.
    ///
    /// The old behavior only changed selectedCategory: the detail area still
    /// showed the results page, the user clicked the category and saw no
    /// change, thinking they had mis-clicked — while the filter had in fact
    /// already changed.
    @Test func selectingCategoryDismissesCleanResult() {
        let vm = makeVM()
        vm.cleanPhase = .done
        vm.selectCategory(.xcode)

        #expect(vm.cleanPhase == .idle)
        #expect(vm.selectedCategory == .xcode)
    }

    /// Switching categories in other states should not touch cleanPhase: the confirming and cleaning state machines must be preserved.
    @Test func selectingCategoryKeepsOtherCleanPhases() {
        let vm = makeVM()
        vm.requestClean()
        vm.selectCategory(.node)

        #expect(vm.cleanPhase == .confirming)
        #expect(vm.selectedCategory == .node)
    }
}
