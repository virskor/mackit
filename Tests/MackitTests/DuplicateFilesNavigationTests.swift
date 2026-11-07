import Foundation
import Testing

@testable import Mackit

/// The contract between the duplicate-file tool page and the app's
/// navigation.
///
/// The page is a sidebar destination the user flips through, while the scan
/// behind it traverses the home folder and compares file contents. These
/// tests pin the contract from the view model's side: no sidebar route may
/// discard the scanned groups (the same rule the large-file walk, the disk
/// analysis measurement and the Homebrew snapshot follow), entering the page
/// never starts a scan on its own, and every route out must clear the page's
/// flag so the detail area follows the selection.
///
/// The model is fixture-backed, so nothing here touches the real disk.
@MainActor
struct DuplicateFilesNavigationTests {
    /// Counts the scans a fixture model started, so "did not start another
    /// one" is stated directly rather than inferred from the results.
    private final class ScanCounter: @unchecked Sendable {
        var scans = 0
    }

    private func makeModel(counters: ScanCounter = ScanCounter()) -> (DuplicatesModel, ScanCounter) {
        let model = DuplicatesModel(
            rootPath: "/Users/x",
            scan: { _, _, _ in
                counters.scans += 1
                return AsyncStream(DuplicateFileScanEvent.self) { continuation in
                    continuation.yield(.found(DuplicateGroup(id: "one", files: [
                        DuplicateFile(
                            path: "/Users/x/set/copy0.bin", name: "copy0.bin", size: 1_000_000,
                            modified: nil, parentPath: "/Users/x/set",
                            nodeIdentity: FileSystem.NodeIdentity(device: 1, node: 1)
                        ),
                        DuplicateFile(
                            path: "/Users/x/set/copy1.bin", name: "copy1.bin", size: 1_000_000,
                            modified: nil, parentPath: "/Users/x/set",
                            nodeIdentity: FileSystem.NodeIdentity(device: 1, node: 2)
                        ),
                    ])))
                    continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
                    continuation.finish()
                }
            }
        )
        return (model, counters)
    }

    @Test func openingTheToolClearsEverySiblingPage() {
        let (model, _) = makeModel()
        let vm = AppViewModel(statsPolling: false, duplicates: model)

        vm.showSettings()
        vm.showHomebrew()
        vm.showDuplicateFiles()

        #expect(vm.showsDuplicateFiles)
        #expect(!vm.showsSettings)
        #expect(!vm.showsHardware)
        #expect(!vm.showsGeneralCleanup)
        #expect(!vm.showsDiskAnalysis)
        #expect(!vm.showsHomebrew)
        #expect(!vm.showsLargeFiles)
        #expect(!vm.showsAppUninstall)
        #expect(vm.selectedCategory == nil, "the tool is not a category filter")
    }

    @Test func enteringThePageDoesNotStartAScan() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, duplicates: model)

        vm.showDuplicateFiles()

        #expect(counters.scans == 0, "a home-directory scan with content comparison is minutes of IO; the start screen's button starts it")
        #expect(!model.isScanning)
    }

    @Test func leavingAndComingBackKeepsTheScannedGroups() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, duplicates: model)

        vm.showDuplicateFiles()
        model.startScan()
        await model.waitUntilSettled()
        #expect(counters.scans == 1)
        #expect(model.groups.count == 1)

        vm.showSettings()
        vm.showDuplicateFiles()
        await model.waitUntilSettled()

        #expect(counters.scans == 1, "coming back to a finished list is instant — the scan belongs to the session")
        #expect(model.groups.count == 1)
    }

    @Test func everyRouteOutOfTheToolClearsItsFlag() async {
        let (model, counters) = makeModel()
        let vm = AppViewModel(statsPolling: false, duplicates: model)

        vm.showDuplicateFiles()
        model.startScan()
        await model.waitUntilSettled()
        #expect(counters.scans == 1)

        // Every sibling route clears the tool's flag. The hardware page is
        // in the list on purpose: it samples the machine on entry, which is
        // exactly the kind of side effect a page-switch contract should not
        // depend on.
        vm.showGeneralCleanup()
        #expect(!vm.showsDuplicateFiles)

        vm.showDuplicateFiles()
        vm.showDiskAnalysis()
        #expect(!vm.showsDuplicateFiles)
        #expect(vm.showsDiskAnalysis)

        vm.showDuplicateFiles()
        vm.showHomebrew()
        #expect(!vm.showsDuplicateFiles)
        #expect(vm.showsHomebrew)

        vm.showDuplicateFiles()
        vm.showLargeFiles()
        #expect(!vm.showsDuplicateFiles)
        #expect(vm.showsLargeFiles)

        vm.showDuplicateFiles()
        vm.showAppUninstall()
        #expect(!vm.showsDuplicateFiles)
        #expect(vm.showsAppUninstall)

        vm.showDuplicateFiles()
        vm.showHardware()
        #expect(!vm.showsDuplicateFiles)

        vm.showDuplicateFiles()
        vm.showSettings()
        #expect(!vm.showsDuplicateFiles)

        vm.showDuplicateFiles()
        vm.selectCategory(nil)
        #expect(!vm.showsDuplicateFiles)

        // None of the routes discarded the scanned groups, and none started
        // a second scan.
        #expect(counters.scans == 1)
        #expect(model.groups.count == 1)
    }
}
