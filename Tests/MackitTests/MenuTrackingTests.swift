import Foundation
import Testing

@testable import Mackit

/// Verifies that snapshot publishing is suspended during menu tracking.
///
/// Background: `MenuBarExtra`'s menu content is hosted by SwiftUI into an
/// NSMenu and rebuilds the menu items on every change. While the menu is
/// open the main thread is stuck in AppKit's modal tracking loop, but menu
/// item actions execute inside that loop (clicking "Rescan", clicking a
/// toggle — both), and at that moment the main thread is alive — publishing a
/// snapshot then would re-host the NSMenu and interrupt AppKit's mouse
/// tracking: the highlight resets, the row under the pointer is replaced, and
/// sliding the mouse in cannot select any row.
/// Therefore nothing is published for the entire tracking duration, with a
/// catch-up publish on close.
@MainActor
struct MenuTrackingTests {
    private func makeVM() -> AppViewModel { AppViewModel(statsPolling: false) }

    private func makeItem(id: String, size: Int64 = 1024) -> JunkItem {
        JunkItem(
            ruleID: "test.\(id)",
            title: id,
            detail: "test",
            path: "/tmp/mackit-\(id)",
            category: .xcode,
            risk: .safe,
            size: size
        )
    }

    /// While the menu is open, scan events never enter the snapshot: an open menu is never rebuilt.
    @Test func scanEventsDoNotUpdateSnapshotWhileMenuIsOpen() async {
        let vm = makeVM()
        vm.phase = .scanning
        vm.publishMenuSnapshot(force: true)
        let before = vm.menuSnapshot

        vm.menuDidBeginTracking()
        for completed in 1...100 {
            vm.apply(.progress(completed: completed, total: 100, label: "unit \(completed)"))
        }
        vm.apply(.discovered([makeItem(id: "a")]))

        // The snapshot does not move at all, while the live state advances as usual
        #expect(vm.menuSnapshot == before)
        #expect(vm.progressFraction == 1)
        #expect(vm.menuSnapshot.itemCount == 0)
        #expect(vm.items.count == 1)
    }

    /// The catch-up publish happens as soon as the menu closes; it must not stay on the old numbers.
    @Test func snapshotCatchesUpWhenMenuCloses() async {
        let vm = makeVM()
        vm.phase = .scanning
        vm.publishMenuSnapshot(force: true)

        vm.menuDidBeginTracking()
        for completed in 1...50 {
            vm.apply(.progress(completed: completed, total: 100, label: "unit \(completed)"))
        }
        vm.apply(.discovered([makeItem(id: "a")]))

        vm.menuDidEndTracking()

        #expect(vm.menuSnapshot.percent == 50)
        #expect(vm.menuSnapshot.itemCount == 1)
        #expect(vm.menuSnapshot.totalSize == 1024)
    }

    /// Nested menus (submenus) must wait until the last level closes before the catch-up publish.
    @Test func nestedMenusKeepFreezeUntilLastClose() async {
        let vm = makeVM()
        vm.phase = .scanning
        vm.publishMenuSnapshot(force: true)
        let before = vm.menuSnapshot

        vm.menuDidBeginTracking()
        vm.menuDidBeginTracking()
        vm.apply(.progress(completed: 20, total: 100, label: "unit"))

        // Still frozen after closing one level
        vm.menuDidEndTracking()
        #expect(vm.menuSnapshot == before)

        vm.menuDidEndTracking()
        #expect(vm.menuSnapshot.percent == 20)
    }

    /// Without a paired end notification, the freeze must not become a permanent freeze.
    @Test func freezeIsAbandonedAfterMaxFreeze() async {
        let vm = makeVM()
        vm.phase = .scanning
        vm.publishMenuSnapshot(force: true)
        vm.maxMenuFreeze = .milliseconds(50)

        vm.menuDidBeginTracking()
        vm.apply(.progress(completed: 10, total: 100, label: "early"))
        #expect(vm.menuSnapshot.percent == 0)

        try? await Task.sleep(for: .milliseconds(120))
        vm.apply(.progress(completed: 90, total: 100, label: "late"))

        // Publishing resumes after the fallback duration, and the menu catches up with the live state again
        #expect(vm.menuSnapshot.percent == 90)
    }

    /// After the tracking state resets, subsequent menu opens/closes work normally and do not lock the snapshot permanently.
    @Test func trackingRecoversAfterAbandonedFreeze() async {
        let vm = makeVM()
        vm.phase = .scanning
        vm.publishMenuSnapshot(force: true)
        vm.maxMenuFreeze = .milliseconds(50)

        vm.menuDidBeginTracking()
        try? await Task.sleep(for: .milliseconds(120))
        vm.apply(.progress(completed: 30, total: 100, label: "a"))
        #expect(vm.menuSnapshot.percent == 30)

        // The reset happens in the publish path; reopening the menu afterwards should freeze again
        vm.menuDidBeginTracking()
        vm.apply(.progress(completed: 60, total: 100, label: "b"))
        #expect(vm.menuSnapshot.percent == 30)

        vm.menuDidEndTracking()
        #expect(vm.menuSnapshot.percent == 60)
    }

    /// Explicit user actions (selection) still take effect immediately when the menu is closed, unaffected by the freeze.
    @Test func userActionsStillPublishImmediatelyWhenMenuClosed() async {
        let vm = makeVM()
        vm.autoSelectRisk = .none
        let item = makeItem(id: "a")
        try? await Task.sleep(for: .milliseconds(260))
        vm.apply(.discovered([item]))
        #expect(vm.menuSnapshot.itemCount == 1)

        vm.toggle(item)
        #expect(vm.menuSnapshot.selectedCount == 1)
        #expect(vm.menuSnapshot.selectedSize == 1024)
    }
}
