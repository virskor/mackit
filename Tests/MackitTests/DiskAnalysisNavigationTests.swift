import Foundation
import Testing

@testable import Mackit

/// The contract between the tool page and its measurement.
///
/// They live in different scopes on purpose: the page is a sidebar destination
/// the user flips through, while a whole-disk measurement is minutes of IO. The
/// page used to cancel the scan on every exit, which threw the work away and —
/// because a whole-disk scan drops the tree when it starts — left the tool
/// looking as if it had lost its state. These tests pin the corrected contract
/// from the view model's side: no sidebar route may end the scan, and the
/// user's own stop still must.
///
/// The model is fixture-backed, so nothing here touches the real disk.
/// `startScan` raises its flag synchronously, which is all these assertions
/// need — no waiting on a real traversal.
@MainActor
struct DiskAnalysisNavigationTests {
    private func makeFixture() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-disk-nav-\(UUID().uuidString)", isDirectory: true)
        let big = base.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1024).write(to: big.appendingPathComponent("a.bin"))
        return base
    }

    @Test func leavingTheToolPageKeepsItsScanRunning() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        let vm = AppViewModel(statsPolling: false, diskAnalysis: model)
        defer { model.cancelScan() }

        vm.showDiskAnalysis()
        model.startScan()
        #expect(model.isScanning)
        #expect(model.scanStartCount == 1)

        // Every sidebar route out of the page, one after another: none may
        // cancel the measurement, and re-entering must not start a second one.
        vm.showSettings()
        #expect(!vm.showsDiskAnalysis)
        #expect(model.isScanning, "opening settings must not cancel the disk scan")

        vm.showDiskAnalysis()
        #expect(model.isScanning)
        #expect(model.scanStartCount == 1, "coming back must not start another scan")

        vm.selectCategory(nil)
        #expect(!vm.showsDiskAnalysis)
        #expect(model.isScanning, "picking a category must not cancel the disk scan")

        // The general module rather than the hardware page: the latter samples
        // GPU, battery and display state on entry, and a page-switch contract
        // has no business depending on the machine having them.
        vm.showGeneralCleanup()
        #expect(!vm.showsDiskAnalysis)
        #expect(model.isScanning, "opening another module must not cancel the disk scan")
    }

    /// The fix must not have made a scan unstoppable: the page's own stop is
    /// still the way out.
    @Test func theUsersStopStillEndsTheScan() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        let vm = AppViewModel(statsPolling: false, diskAnalysis: model)

        vm.showDiskAnalysis()
        model.startScan()
        #expect(model.isScanning)

        model.cancelScan()
        #expect(!model.isScanning)
        #expect(model.root == nil, "a stopped whole-disk scan presents nothing yet")
    }
}
