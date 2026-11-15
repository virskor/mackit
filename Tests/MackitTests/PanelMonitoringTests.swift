import Foundation
import Testing

@testable import Mackit

/// The tray panel's monitoring exception and the snapshot fields the new
/// processor/memory pages read.
///
/// The panel keeps the two-second polling alive even when every menu-bar
/// toggle is off, while a closed panel still skips the work. These tests pin
/// that contract, plus the immediate snapshot update a chart picker expects.
@MainActor
struct PanelMonitoringTests {
    private func makeVM() -> AppViewModel { AppViewModel(statsPolling: false) }

    /// With every toggle off the ordinary sample path skips; the panel's
    /// explicit first frame must still produce data for its detail pages.
    @Test func beginPanelMonitoringSamplesWithEveryToggleOff() {
        let vm = makeVM()
        vm.showMenuBarCPU = false
        vm.showMenuBarMemory = false
        vm.showMenuBarTemperature = false
        #expect(vm.menuSnapshot.stats.memoryTotal == 0)

        vm.beginPanelMonitoring()

        #expect(vm.menuSnapshot.stats.memoryTotal > 0)
    }

    /// A chart picker rewrites the snapshot immediately: the page's Binding
    /// reads the selected range from the snapshot, so waiting for the next
    /// two-second sample would leave the control out of sync with the chart.
    @Test func chartSelectionsReachTheSnapshotImmediately() {
        let vm = makeVM()
        vm.sampleSystemStats()

        vm.selectCPUChartRange(.oneHour)

        #expect(vm.menuSnapshot.cpuChartRange == .oneHour)
        #expect(vm.menuSnapshot.cpuUserSeries.count <= CPUChartRange.chartPointCount)
        #expect(vm.menuSnapshot.cpuSystemSeries.count <= CPUChartRange.chartPointCount)

        vm.selectMemoryChartMetric(.compressed)

        #expect(vm.menuSnapshot.memoryChartMetric == .compressed)
        #expect(vm.menuSnapshot.memoryChartSeries.count <= AppViewModel.memoryHistoryCapacity)
    }

    /// The remote merge only owns the scan half; the monitoring fields the
    /// agent sampled itself must survive the broadcast untouched.
    @Test func remoteScanStateKeepsMonitoringFields() {
        let vm = makeVM()
        vm.isAgentProcess = true
        vm.sampleSystemStats()
        let before = vm.menuSnapshot.stats

        vm.applyRemoteScanState(
            ScanState(
                phase: "scanning",
                cleanPhase: "idle",
                percent: 40,
                totalSize: 5_000,
                itemCount: 3,
                selectedCount: 2,
                selectedSize: 3_000
            )
        )

        #expect(vm.menuSnapshot.stats == before)
        #expect(vm.menuSnapshot.phase == .scanning)
        #expect(vm.menuSnapshot.percent == 40)
    }
}
