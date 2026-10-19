import Foundation
import Testing

@testable import Mackit

/// Verifies that the agent-side snapshot merge is not wiped out by this
/// process's publish path.
///
/// Background: the tray panel header needs to show "reclaimable size / item
/// count", data that only exists in the main app's VM, broadcast to the agent
/// by `AppBridge` and merged into the snapshot by `applyRemoteScanState`.
/// But the agent's own VM also polls system stats once every two seconds and
/// publishes a snapshot; if the publish recomputes the scan fields from local
/// values (the agent never scans, so they are always empty), the merged-in
/// numbers are immediately zeroed out and the panel flickers "0 B / 0 items"
/// during scans. Therefore the agent process's publish only updates the
/// monitoring half, and the sole source of scan fields is the broadcast
/// (see `publishMenuSnapshot`).
@MainActor
struct AgentSnapshotMergeTests {
    private func makeVM() -> AppViewModel { AppViewModel(statsPolling: false) }

    private func remoteState(
        phase: String = "scanning",
        percent: Int = 40,
        totalSize: Int64 = 5000,
        itemCount: Int = 3,
        selectedCount: Int = 2,
        selectedSize: Int64 = 3000
    ) -> ScanState {
        ScanState(
            phase: phase,
            cleanPhase: "idle",
            percent: percent,
            totalSize: totalSize,
            itemCount: itemCount,
            selectedCount: selectedCount,
            selectedSize: selectedSize
        )
    }

    /// The agent's monitoring polling (once every two seconds) must not wipe out the scan numbers broadcast in.
    @Test func agentPollingKeepsRemoteScanFields() async {
        let vm = makeVM()
        vm.isAgentProcess = true
        vm.applyRemoteScanState(remoteState())

        // The sampling + publish the agent runs every two seconds
        vm.sampleSystemStats()

        #expect(vm.menuSnapshot.phase == .scanning)
        #expect(vm.menuSnapshot.percent == 40)
        #expect(vm.menuSnapshot.totalSize == 5000)
        #expect(vm.menuSnapshot.itemCount == 3)
        #expect(vm.menuSnapshot.selectedCount == 2)
        #expect(vm.menuSnapshot.selectedSize == 3000)
    }

    /// The catch-up publish when the menu closes likewise only updates the monitoring fields; scan numbers are kept as-is.
    @Test func agentMenuCloseCatchUpKeepsRemoteScanFields() async {
        let vm = makeVM()
        vm.isAgentProcess = true
        vm.applyRemoteScanState(remoteState())

        vm.menuDidBeginTracking()
        vm.menuDidEndTracking()

        #expect(vm.menuSnapshot.totalSize == 5000)
        #expect(vm.menuSnapshot.itemCount == 3)
    }

    /// The main app side still recomputes scan fields from local state: the role gate must not block the main app too.
    @Test func mainProcessPublishStillWritesLocalScanFields() async {
        let vm = makeVM()
        vm.isAgentProcess = false
        vm.phase = .scanning
        vm.apply(.discovered([JunkItem(
            ruleID: "test.a",
            title: "a",
            detail: "test",
            path: "/tmp/mackit-a",
            category: .xcode,
            risk: .safe,
            size: 1024
        )]))

        #expect(vm.menuSnapshot.itemCount == 1)
        #expect(vm.menuSnapshot.totalSize == 1024)
        #expect(vm.menuSnapshot.phase == .scanning)
    }

    /// Exit state: the reclaimable totals and item count are kept as-is, while the selection is zeroed out.
    ///
    /// After "close the window and quit", the tray panel is the only place the previous scan results are still visible to the user; zeroing them would force a rescan every time the user closes the window and reopens the tray. Selection belongs to the main window session and is discarded along with the main app.
    @Test func scanStateForExitKeepsTotalsAndDropsSelection() async {
        let vm = AppViewModel(statsPolling: false)
        vm.isAgentProcess = false
        vm.apply(.discovered([
            JunkItem(
                ruleID: "test.a",
                title: "a",
                detail: "test",
                path: "/tmp/mackit-a",
                category: .xcode,
                risk: .safe,
                size: 1024
            ),
            JunkItem(
                ruleID: "test.b",
                title: "b",
                detail: "test",
                path: "/tmp/mackit-b",
                category: .xcode,
                risk: .safe,
                size: 1024
            )
        ]))
        vm.selection = ["test.a::/tmp/mackit-a"]

        let state = vm.scanStateForExit()

        #expect(state.totalSize == 2048)
        #expect(state.itemCount == 2)
        #expect(state.selectedCount == 0)
        #expect(state.selectedSize == 0)
    }

    /// The agent merges the exit state: totals stay in the panel, the selection
    /// is zeroed, and this process's monitoring polling does not wipe that half out again.
    @Test func agentKeepsReclaimableTotalsAfterMainAppExits() async {
        let vm = makeVM()
        vm.isAgentProcess = true
        vm.applyRemoteScanState(remoteState())

        // Broadcast just before the main app exits: totals and item count kept, selection zeroed
        vm.applyRemoteScanState(ScanState(
            phase: "done",
            cleanPhase: "idle",
            percent: 100,
            totalSize: 5000,
            itemCount: 3,
            selectedCount: 0,
            selectedSize: 0
        ))
        vm.sampleSystemStats()

        #expect(vm.menuSnapshot.phase == .done)
        #expect(vm.menuSnapshot.totalSize == 5000)
        #expect(vm.menuSnapshot.itemCount == 3)
        #expect(vm.menuSnapshot.selectedCount == 0)
        #expect(vm.menuSnapshot.selectedSize == 0)
    }

    /// A zeroed broadcast from a brand new main app session still takes effect: when the main app restarts and has scanned nothing, the tray must not keep stale numbers from the previous session.
    @Test func agentAppliesZeroedStateFromFreshSession() async {
        let vm = makeVM()
        vm.isAgentProcess = true
        vm.applyRemoteScanState(remoteState())

        vm.applyRemoteScanState(ScanState())
        vm.sampleSystemStats()

        #expect(vm.menuSnapshot.phase == .idle)
        #expect(vm.menuSnapshot.totalSize == 0)
        #expect(vm.menuSnapshot.itemCount == 0)
        #expect(vm.menuSnapshot.selectedCount == 0)
    }
}
