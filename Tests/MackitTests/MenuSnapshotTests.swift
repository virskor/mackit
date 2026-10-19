import Foundation
import Testing

@testable import Mackit

/// Verifies the menu bar snapshot's throttling and immediacy.
///
/// Background: `MenuBarExtra`'s menu content is hosted into an NSMenu by
/// SwiftUI, relying on rebuilding the menu items on every change. The scan
/// advances at the pace of "each work unit", so if the menu read the live
/// state directly it would be beaten into a flicker by dozens of
/// rearrangements per second when opened. The menu therefore only reads
/// `vm.menuSnapshot`: scan events are throttled by interval, while phase
/// transitions and user actions take effect immediately.
@MainActor
struct MenuSnapshotTests {
    private func makeVM() -> AppViewModel { AppViewModel(statsPolling: false) }

    private func makeItem(id: String) -> JunkItem {
        JunkItem(
            ruleID: "test.\(id)",
            title: id,
            detail: "test",
            path: "/tmp/mackit-\(id)",
            category: .xcode,
            risk: .safe,
            size: 1024
        )
    }

    /// A burst of scan events arriving at the same moment buys only one
    /// snapshot update.
    /// An open menu rebuilt dozens of times per second is the flicker the
    /// user sees.
    @Test func burstOfScanEventsCollapsesIntoSingleUpdate() async {
        let vm = makeVM()

        for completed in 1...100 {
            vm.apply(.progress(completed: completed, total: 100, label: "unit \(completed)"))
        }

        // The first event publishes once (no previous publish time); the rest
        // all fall inside the publish interval and are swallowed
        #expect(vm.menuSnapshot.percent == 1)
        // The live state is unaffected: the progress bar is still exact
        #expect(vm.progressFraction == 1)
        #expect(vm.progressLabel == "unit 100")
    }

    /// After the interval the snapshot must catch up; it cannot stay behind
    /// forever.
    @Test func snapshotCatchesUpAfterInterval() async {
        let vm = makeVM()
        for completed in 1...100 {
            vm.apply(.progress(completed: completed, total: 100, label: "unit \(completed)"))
        }
        #expect(vm.menuSnapshot.percent == 1)

        try? await Task.sleep(for: .milliseconds(260))
        vm.apply(.progress(completed: 40, total: 100, label: "later"))

        #expect(vm.menuSnapshot.percent == 40)
    }

    /// Phase transitions must take effect immediately: the menu must switch
    /// from "Rescan" to the progress row right away.
    @Test func phaseTransitionsPublishImmediately() async {
        let vm = makeVM()
        vm.phase = .scanning
        vm.publishMenuSnapshot(force: true)
        #expect(vm.menuSnapshot.phase == .scanning)

        vm.phase = .done
        vm.publishMenuSnapshot(force: true)
        #expect(vm.menuSnapshot.phase == .done)
    }

    /// A user's explicit check must reach the menu immediately, without
    /// waiting for the interval.
    @Test func userSelectionPublishesImmediately() async {
        let vm = makeVM()
        // Set the level explicitly to avoid depending on settings values that
        // may linger in UserDefaults
        vm.autoSelectRisk = .safe
        let item = makeItem(id: "a")
        try? await Task.sleep(for: .milliseconds(260))
        vm.apply(.discovered([item]))
        // Safe items are auto-checked; count and size both enter the snapshot
        #expect(vm.menuSnapshot.selectedCount == 1)
        #expect(vm.menuSnapshot.selectedSize == 1024)

        vm.toggle(item)
        #expect(vm.menuSnapshot.selectedCount == 0)
        #expect(vm.menuSnapshot.selectedSize == 0)
    }

    /// The default level is "do not auto-check": items found by a scan always
    /// wait for the user to check them manually.
    @Test func defaultLevelAutoSelectsNothing() async {
        let vm = makeVM()
        vm.autoSelectRisk = .none
        let item = makeItem(id: "a")
        try? await Task.sleep(for: .milliseconds(260))
        vm.apply(.discovered([item]))

        #expect(vm.selection.isEmpty)
        #expect(vm.menuSnapshot.selectedCount == 0)
        #expect(vm.menuSnapshot.selectedSize == 0)
        // The items themselves still enter the list as usual, just unchecked
        #expect(vm.menuSnapshot.itemCount == 1)
    }

    /// Discovered items must refresh both the count and the total size, so the
    /// menu header stays trustworthy.
    @Test func discoveredItemsUpdateTotals() async {
        let vm = makeVM()
        try? await Task.sleep(for: .milliseconds(260))
        vm.apply(.discovered([makeItem(id: "a"), makeItem(id: "b")]))

        #expect(vm.menuSnapshot.itemCount == 2)
        #expect(vm.menuSnapshot.totalSize == 2048)
    }

    /// System stat samples must land in the snapshot: the tray menu only
    /// reads the snapshot, never the VM's live state directly.
    @Test func statsLandInSnapshot() {
        let vm = makeVM()
        vm.sampleSystemStats()

        #expect(vm.menuSnapshot.stats.memoryTotal > 0)
        #expect(vm.menuSnapshot.stats.memoryUsed + vm.menuSnapshot.stats.memoryFree <= vm.menuSnapshot.stats.memoryTotal)
    }

    /// With all three toggles off there is no sampling: nobody is watching,
    /// and every sample publishes a snapshot, and publishing means rebuilding
    /// the menu items hosted into an NSMenu once more.
    @Test func statsAreSkippedWhenEveryToggleIsOff() {
        let vm = makeVM()
        vm.showMenuBarCPU = false
        vm.showMenuBarMemory = false
        vm.showMenuBarTemperature = false

        vm.sampleSystemStats()

        #expect(vm.menuSnapshot.stats.memoryTotal == 0)
    }

    /// While the menu is open the monitoring numbers do not enter the
    /// snapshot either — sharing the same freeze with scan events, otherwise
    /// a rebuild every two seconds would break up the mouse highlight.
    @Test func statsDoNotUpdateSnapshotWhileMenuIsOpen() {
        let vm = makeVM()
        vm.sampleSystemStats()
        let before = vm.menuSnapshot

        vm.menuDidBeginTracking()
        vm.sampleSystemStats()

        #expect(vm.menuSnapshot == before)
    }
}
