import AppKit
import Foundation
import Testing

@testable import Mackit

/// Visibility rules and position persistence of the desktop floating stats window.
///
/// The panel itself (NSPanel, drag gestures) depends on a real window server,
/// so the tests only cover what can be verified offline: when it should show,
/// and whether position reads and writes are correct.
@MainActor
struct StatsOverlayTests {
    /// It shows only when the master switch is on and at least one monitor is
    /// enabled; with all three monitors off the floating window would be empty,
    /// so per the `statsOverlayVisible` contract it should be hidden.
    @Test func overlayVisibilityFollowsToggles() {
        let vm = AppViewModel(statsPolling: false)
        // Set explicitly, to avoid depending on values that may linger in the real shared settings on the machine
        vm.showDesktopStats = true
        vm.showMenuBarCPU = true
        vm.showMenuBarMemory = true
        vm.showMenuBarTemperature = true

        #expect(vm.statsOverlayVisible)

        vm.showMenuBarCPU = false
        vm.showMenuBarMemory = false
        vm.showMenuBarTemperature = false
        #expect(!vm.statsOverlayVisible, "all three monitor switches off: the floating window is empty, so it should collapse")

        // Any single monitor switch on brings the floating window back
        vm.showMenuBarTemperature = true
        #expect(vm.statsOverlayVisible)

        // The master switch overrides everything
        vm.showDesktopStats = false
        #expect(!vm.statsOverlayVisible)
    }

    /// A saved position must read back exactly; a missing file or corrupted
    /// content both count as "no position" (the caller falls back to the default
    /// position) — it must not crash and must not report a fake position.
    @Test func overlayPositionRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-overlay-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overlay-position.plist")

        #expect(OverlayPositionStore.load(fileURL: file) == nil, "should return nil when there is no file")

        OverlayPositionStore.save(NSPoint(x: 120.5, y: 800), fileURL: file)
        #expect(OverlayPositionStore.load(fileURL: file) == NSPoint(x: 120.5, y: 800))

        try? "not-a-plist".write(to: file, atomically: true, encoding: .utf8)
        #expect(OverlayPositionStore.load(fileURL: file) == nil, "bad content must not yield a fake position")
    }
}
