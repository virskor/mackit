import Foundation
import Testing

@testable import Mackit

/// The contract between the large-file analysis tool page and the app's
/// navigation.
///
/// The page is a sidebar destination the user flips through, while the walk
/// behind it traverses the whole startup disk. These tests pin the contract
/// from the view model's side: no sidebar route may discard the walked list
/// (the same rule the disk analysis measurement and the Homebrew snapshot
/// follow), entering the page never starts a walk on its own, and every route
/// out must clear the page's flag so the detail area follows the selection.
///
/// The model is fixture-backed, so nothing here touches the real disk.
@MainActor
struct LargeFilesNavigationTests {
    /// Counts the walks a fixture model started, so "did not start another
    /// one" is stated directly rather than inferred from the results.
    private final class LoadCounter: @unchecked Sendable {
        var walks = 0
    }

    private func makeModel(counters: LoadCounter = LoadCounter()) -> (LargeFilesModel, LoadCounter) {
        let model = LargeFilesModel(
            rootPath: "/Users/x",
            scan: { _, _, _ in
                counters.walks += 1
                return AsyncStream(LargeFileScanEvent.self) { continuation in
                    continuation.yield(.found(LargeFile(
                        path: "/Users/x/big.bin", name: "big.bin", size: 3_000_000_000,
                        modified: nil, parentPath: "/Users/x"
                    )))
                    continuation.yield(.finished(unreadableDirectories: 0))
                    continuation.finish()
                }
            }
        )
        return (model, counters)
    }

    @Test func openingTheToolClearsEverySiblingPage() {
        let (model, _) = makeModel()
        let vm = AppViewModel(statsPolling: false, largeFiles: model)

        vm.showSettings()
        vm.showHomebrew()
        vm.showLargeFiles()

        #expect(vm.showsLargeFiles)
        #expect(!vm.showsSettings)
        #expect(!vm.showsHardware)
        #expect(!vm.showsGeneralCleanup)
        #expect(!vm.showsDiskAnalysis)
        #expect(!vm.showsHomebrew)
        #expect(!vm.showsAppUninstall)
        #expect(vm.selectedCategory == nil, "the tool is not a category filter")
    }

    @Test func enteringThePageDoesNotStartAWalk() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, largeFiles: model)

        vm.showLargeFiles()

        #expect(counters.walks == 0, "a whole-disk walk is minutes of IO; the start screen's button starts it")
        #expect(!model.isScanning)
    }

    @Test func leavingAndComingBackKeepsTheWalkedList() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, largeFiles: model)

        vm.showLargeFiles()
        model.startScan()
        await model.waitUntilSettled()
        #expect(counters.walks == 1)
        #expect(model.files.count == 1)

        vm.showSettings()
        vm.showLargeFiles()
        await model.waitUntilSettled()

        #expect(counters.walks == 1, "coming back to a finished list is instant — the walk belongs to the session")
        #expect(model.files.count == 1)
    }

    @Test func everyRouteOutOfTheToolClearsItsFlag() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, largeFiles: model)

        vm.showLargeFiles()
        model.startScan()
        await model.waitUntilSettled()
        #expect(counters.walks == 1)

        // Every sibling route clears the tool's flag. The hardware page is
        // in the list on purpose: it samples the machine on entry, which is
        // exactly the kind of side effect a page-switch contract should not
        // depend on.
        vm.showGeneralCleanup()
        #expect(!vm.showsLargeFiles)

        vm.showLargeFiles()
        vm.showDiskAnalysis()
        #expect(!vm.showsLargeFiles)
        #expect(vm.showsDiskAnalysis)

        vm.showLargeFiles()
        vm.showHomebrew()
        #expect(!vm.showsLargeFiles)
        #expect(vm.showsHomebrew)

        vm.showLargeFiles()
        vm.showAppUninstall()
        #expect(!vm.showsLargeFiles)
        #expect(vm.showsAppUninstall)

        vm.showLargeFiles()
        vm.showHardware()
        #expect(!vm.showsLargeFiles)

        vm.showLargeFiles()
        vm.showSettings()
        #expect(!vm.showsLargeFiles)

        vm.showLargeFiles()
        vm.selectCategory(nil)
        #expect(!vm.showsLargeFiles)

        // None of the routes discarded the walked list, and none started a
        // second walk.
        #expect(counters.walks == 1)
        #expect(model.files.count == 1)
    }
}
