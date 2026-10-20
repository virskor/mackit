import AppKit
import Foundation
import Testing

@testable import Mackit

/// The quit button on the menu bar panel's memory ranking rows.
///
/// The real processes are never touched: `AppQuitter` takes the pid lookup
/// and the two terminate calls as injected closures, so the decision —
/// graceful first, force as fallback, Mackit's own row quits the whole app —
/// can be driven without signalling anything.
@MainActor
struct AppQuitterTests {
    /// A real, live app to stand in for a ranking row.
    ///
    /// The row only has to resolve to something that is running: the pid
    /// lookup is injected, so any app will do — and the terminate calls are
    /// injected too, so nothing is ever signalled. Nil when this environment
    /// has no GUI apps at all.
    private var liveApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { !$0.isTerminated }
    }

    // MARK: Which app the row belongs to

    /// A row that is Mackit's own main app quits the whole app: quitting only
    /// it would leave the tray agent running with nothing to talk to.
    @Test func mackitsOwnRowQuitsTheWholeApp() {
        #expect(AppQuitter.plan(bundleID: AppIdentity.mainBundleID) == .quitMackit)
    }

    /// Every other row is just asked to quit, including one whose bundle id
    /// could not be read — the pid is what carries the signal.
    @Test func anyOtherRowIsAskedToQuit() {
        #expect(AppQuitter.plan(bundleID: "com.apple.Safari") == .requestQuit)
        #expect(AppQuitter.plan(bundleID: nil) == .requestQuit)
    }

    // MARK: Ordering of the two terminate calls

    /// The graceful quit is tried first, and the force kill is not reached
    /// when it succeeds: killing an app that did respond to the quit event
    /// would cut short whatever it was saving.
    @Test func forceKillIsOnlyTheFallback() throws {
        let app = try #require(liveApp)
        let pid = Int(app.processIdentifier)
        var terminated = 0
        var forced = 0

        let outcome = AppQuitter(resolve: { _ in app }).quit(
            pid: pid,
            terminate: { _ in terminated += 1; return true },
            forceTerminate: { _ in forced += 1; return false }
        ) {}

        #expect(outcome == .quitRequested)
        #expect(terminated == 1)
        #expect(forced == 0)
    }

    /// When the quit event cannot be delivered at all, the force kill is the
    /// only thing left.
    @Test func forceKillHappensWhenTheQuitEventCannotBeDelivered() throws {
        let app = try #require(liveApp)
        let pid = Int(app.processIdentifier)
        var forced = 0

        let outcome = AppQuitter(resolve: { _ in app }).quit(
            pid: pid,
            terminate: { _ in return false },
            forceTerminate: { _ in forced += 1; return true }
        ) {}

        #expect(outcome == .quitRequested)
        #expect(forced == 1)
    }

    /// Both calls failing means there was nothing left to quit.
    @Test func bothCallsFailingLeavesNothingQuit() throws {
        let app = try #require(liveApp)
        let pid = Int(app.processIdentifier)

        let outcome = AppQuitter(resolve: { _ in app }).quit(
            pid: pid,
            terminate: { _ in return false },
            forceTerminate: { _ in return false }
        ) {}

        #expect(outcome == .alreadyGone)
    }

    // MARK: Processes that are gone

    /// A pid that resolves to nothing is left alone: signalling a pid the
    /// system has handed to another process would kill an unrelated app.
    @Test func deadProcessIsNotSignalled() {
        var signalled = 0

        let outcome = AppQuitter(resolve: { _ in nil }).quit(
            pid: 4242,
            terminate: { _ in signalled += 1; return true },
            forceTerminate: { _ in signalled += 1; return true }
        ) {}

        #expect(outcome == .alreadyGone)
        #expect(signalled == 0)
    }

    // MARK: ViewModel wiring

    /// The panel action survives a row whose process is already gone, and the
    /// ranking is refreshed either way so the panel is never left showing a
    /// process that is not there.
    @Test func quittingAGoneRowRefreshesTheRanking() {
        let vm = AppViewModel(statsPolling: false)
        // No pid can be this large, so the row cannot resolve to anything —
        // and no signal is sent to any real process.
        let gone = AppMemoryEntry(pid: Int.max, name: "Gone", path: "", bytes: 1024)

        vm.quitApp(gone)

        #expect(vm.menuSnapshot.stats.memoryTotal > 0)
    }
}
