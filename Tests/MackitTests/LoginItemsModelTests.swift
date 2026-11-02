import Foundation
import Testing

@testable import Mackit

/// The startup-items model's contracts: the toggle path per item kind,
/// the privileged-helper gating for system daemons, and the grouping
/// and search the page renders.
///
/// Every dependency is injected — the scan, the apply, the helper's
/// install and state — so nothing here touches a real launchd, a real
/// helper, or a real /Library.
@MainActor
struct LoginItemsModelTests {
    /// A fixture item.
    private func item(
        _ id: String,
        label: String,
        enabled: Bool,
        kind: LoginItem.Kind = .userAgent,
        app: MatchedApp? = nil
    ) -> LoginItem {
        LoginItem(
            id: id,
            kind: kind,
            label: label,
            plistPath: kind == .legacyLoginItem
                ? nil
                : "/Users/x/Library/LaunchAgents/\(label).plist",
            targetPath: kind == .legacyLoginItem ? "/Applications/Target.app" : nil,
            app: app,
            isEnabled: enabled
        )
    }

    /// A model with canned scan data and recording seams.
    ///
    /// `helperState` is read through a mutable fake so an install can
    /// flip it: the model re-reads the state after a successful install,
    /// and a static "not installed" answer would describe a machine
    /// where the install did nothing.
    ///
    /// `scanCounter` is opt-in: the lifecycle contracts below are about
    /// *how many times* the scan runs, which the canned data alone
    /// cannot show — a second visit that rescanned would still leave
    /// `items.count == 1` and pass silently.
    private func makeModel(
        items: [LoginItem],
        scanCounter: ScanCounter? = nil,
        apply: @escaping (LoginItem, Bool) async -> HelperOutcome = { _, _ in .success },
        helperState: HelperClient.InstalledState = .notInstalled,
        install: @escaping @Sendable () -> ElevatedHelper.Outcome = { .succeeded },
        uninstall: @escaping @Sendable () async -> HelperOutcome = { .success },
        uninstallElevated: @escaping @Sendable () -> ElevatedHelper.Outcome = { .succeeded }
    ) -> (LoginItemsModel, ApplyRecorder, HelperStateFake) {
        let recorder = ApplyRecorder()
        let state = HelperStateFake(helperState)
        let model = LoginItemsModel(
            scan: {
                scanCounter?.bump()
                return items
            },
            apply: { item, enabled in
                recorder.record(item.id, enabled)
                return await apply(item, enabled)
            },
            readHelperState: { state.read() },
            // A successful install leaves the helper on disk; the fake
            // records that, exactly as the real install's files would.
            installHelper: {
                let outcome = install()
                if case .succeeded = outcome {
                    state.markInstalled(version: "1.2.3")
                }
                return outcome
            },
            uninstallHelper: {
                let outcome = await uninstall()
                // The daemon removes its own files as root; the fake
                // records that, exactly as the real uninstall would.
                if outcome.succeeded {
                    state.markRemoved()
                }
                return outcome
            },
            // The elevated fallback removes the root-owned files through
            // a one-shot root run; the fake records that the same way.
            uninstallHelperElevated: {
                let outcome = uninstallElevated()
                if case .succeeded = outcome {
                    state.markRemoved()
                }
                return outcome
            },
            appVersion: "1.2.3",
            iconForPath: { _ in nil }
        )
        return (model, recorder, state)
    }

    /// One recorded toggle: which item, to what state. A struct rather
    /// than a tuple so the recorder's calls compare with `==`.
    private struct ApplyCall: Equatable {
        let itemID: String
        let enabled: Bool
    }

    /// The helper's on-disk state, flippable by a successful install.
    private final class HelperStateFake: @unchecked Sendable {
        private let lock = NSLock()
        private var state: HelperClient.InstalledState

        init(_ state: HelperClient.InstalledState) {
            self.state = state
        }

        func read() -> HelperClient.InstalledState {
            lock.lock()
            defer { lock.unlock() }
            return state
        }

        func markInstalled(version: String) {
            lock.lock()
            state = .installed(version: version)
            lock.unlock()
        }

        func markRemoved() {
            lock.lock()
            state = .notInstalled
            lock.unlock()
        }
    }

    private final class ApplyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [ApplyCall] = []

        func record(_ id: String, _ enabled: Bool) {
            lock.lock()
            records.append(ApplyCall(itemID: id, enabled: enabled))
            lock.unlock()
        }

        var calls: [ApplyCall] {
            lock.lock()
            defer { lock.unlock() }
            return records
        }
    }

    /// Counts how many times the injected scan closure ran.
    private final class ScanCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func bump() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    // MARK: Scan lifecycle

    @Test func activateScansOncePerSession() async {
        let counter = ScanCounter()
        let (model, _, _) = makeModel(
            items: [item("a", label: "com.a", enabled: true)],
            scanCounter: counter
        )
        model.activate()
        await model.waitUntilSettled()
        #expect(model.hasScanned)
        #expect(model.items.count == 1)
        #expect(model.groups.count == 1)
        #expect(counter.value == 1, "the first visit scans once")

        // A second visit is instant: no rescan.
        model.activate()
        await model.waitUntilSettled()
        #expect(model.items.count == 1)
        #expect(counter.value == 1, "a second visit must not rescan")
    }

    @Test func rescanReplacesTheList() async {
        let counter = ScanCounter()
        let (model, _, _) = makeModel(
            items: [item("a", label: "com.a", enabled: true)],
            scanCounter: counter
        )
        model.activate()
        await model.waitUntilSettled()
        #expect(counter.value == 1)
        model.rescan()
        await model.waitUntilSettled()
        #expect(counter.value == 2, "a rescan runs the scan again")
        #expect(model.items.count == 1)
    }

    // MARK: Toggling agents

    @Test func togglingAnAgentFlipsItsState() async {
        let (model, recorder, _) = makeModel(items: [item("a", label: "com.a", enabled: true)])
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: false)
        await model.waitUntilSettled()

        #expect(recorder.calls == [ApplyCall(itemID: "a", enabled: false)])
        #expect(model.items[0].isEnabled == false)
        #expect(model.groups[0].status == .allDisabled)
    }

    @Test func togglingToTheSameStateIsANoOp() async {
        let (model, recorder, _) = makeModel(items: [item("a", label: "com.a", enabled: true)])
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: true)
        await model.waitUntilSettled()

        #expect(recorder.calls.isEmpty)
    }

    @Test func aFailedToggleLeavesTheStateAndReports() async {
        let (model, _, _) = makeModel(
            items: [item("a", label: "com.a", enabled: true)],
            apply: { _, _ in .failed("launchctl exited 5") }
        )
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: false)
        await model.waitUntilSettled()

        // The switch snaps back: the state only moves on success.
        #expect(model.items[0].isEnabled == true)
        #expect(model.notice?.message == "launchctl exited 5")
        #expect(model.notice?.isError == true)
    }

    @Test func theGroupSwitchTogglesEveryItem() async {
        let foo = MatchedApp(name: "Foo", path: "/Applications/Foo.app")
        let (model, recorder, _) = makeModel(items: [
            item("a", label: "com.foo.agent", enabled: true, app: foo),
            item("b", label: "com.foo.helper", enabled: true, app: foo)
        ])
        model.activate()
        await model.waitUntilSettled()

        model.setGroupEnabled(model.groups[0], enabled: false)
        await model.waitUntilSettled()

        #expect(recorder.calls.count == 2)
        #expect(model.items.allSatisfy { !$0.isEnabled })
        #expect(model.groups[0].status == .allDisabled)
    }

    // MARK: The privileged-helper gate

    @Test func aDaemonToggleWithoutTheHelperAsksForTheInstall() async {
        let (model, recorder, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .notInstalled
        )
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: false)
        await model.waitUntilSettled()

        // Nothing is applied yet; the change is held for the sheet.
        #expect(recorder.calls.isEmpty)
        #expect(model.items[0].isEnabled == true)
        #expect(model.pendingChange == LoginItemsModel.PendingChange(itemIDs: ["d"], enabled: false))
    }

    @Test func confirmingTheInstallAppliesTheHeldChange() async {
        let (model, recorder, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .notInstalled,
            install: { .succeeded }
        )
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: false)
        await model.waitUntilSettled()
        model.confirmPendingChange()
        await model.waitUntilSettled()

        // The install ran, then the held change went through.
        #expect(recorder.calls == [ApplyCall(itemID: "d", enabled: false)])
        #expect(model.items[0].isEnabled == false)
        #expect(model.pendingChange == nil)
        #expect(model.helperState.isInstalled)
    }

    @Test func cancellingTheSheetKeepsEverySwitch() async {
        let (model, recorder, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .notInstalled
        )
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: false)
        model.cancelPendingChange()
        await model.waitUntilSettled()

        #expect(recorder.calls.isEmpty)
        #expect(model.items[0].isEnabled == true)
        #expect(model.pendingChange == nil)
        #expect(model.notice == nil)
    }

    @Test func aCancelledPasswordIsANoticeNotAnError() async {
        let (model, recorder, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .notInstalled,
            install: { .cancelled }
        )
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: false)
        model.confirmPendingChange()
        await model.waitUntilSettled()

        #expect(recorder.calls.isEmpty)
        #expect(model.items[0].isEnabled == true)
        #expect(model.notice?.isError == false)
    }

    @Test func aFailedInstallNamesItsCause() async {
        let (model, _, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .notInstalled,
            install: { .failed("launchctl bootstrap: service already bootstrapped") }
        )
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: false)
        model.confirmPendingChange()
        await model.waitUntilSettled()

        #expect(model.notice?.message == "launchctl bootstrap: service already bootstrapped")
        #expect(model.notice?.isError == true)
        #expect(model.items[0].isEnabled == true)
    }

    @Test func aStaleHelperAlsoGatesTheToggle() async {
        let (model, recorder, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            // Installed from an older app version.
            helperState: .installed(version: "1.0.0")
        )
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: false)
        await model.waitUntilSettled()

        #expect(recorder.calls.isEmpty)
        #expect(model.pendingChange != nil)
    }

    @Test func aCurrentHelperLetsTheToggleThrough() async {
        let (model, recorder, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .installed(version: "1.2.3")
        )
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: false)
        await model.waitUntilSettled()

        #expect(recorder.calls == [ApplyCall(itemID: "d", enabled: false)])
        #expect(model.items[0].isEnabled == false)
    }

    @Test func theHelperStateReportsInstallationAndStaleness() {
        let (model, _, _) = makeModel(items: [], helperState: .notInstalled)
        model.refreshHelperState()
        #expect(model.helperState == .notInstalled)
        #expect(!model.helperState.isInstalled)
        #expect(model.helperState.needsInstall)

        let (installed, _, _) = makeModel(items: [], helperState: .installed(version: "1.2.3"))
        installed.refreshHelperState()
        #expect(installed.helperState == .installed(version: "1.2.3", stale: false))
        #expect(installed.helperState.isInstalled)
        #expect(!installed.helperState.needsInstall)

        let (stale, _, _) = makeModel(items: [], helperState: .installed(version: "1.0.0"))
        stale.refreshHelperState()
        #expect(stale.helperState == .installed(version: "1.0.0", stale: true))
        #expect(stale.helperState.needsInstall)
    }

    @Test func anUnreachableHelperIsRepairedByTheInstallPath() async {
        // Files installed, but the daemon does not answer — the state a
        // self-killed uninstall leaves behind. The first toggle fails
        // with the unresponsive notice; the next one goes through the
        // install flow, which reinstalls and then applies the change.
        let phase = PhaseFake()
        let (model, recorder, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            apply: { _, _ in
                phase.reachable ? .success : .failed("connection lost", unreachable: true)
            },
            helperState: .installed(version: "1.2.3"),
            install: {
                // The reinstall brings the daemon back.
                phase.makeReachable()
                return .succeeded
            }
        )
        model.activate()
        await model.waitUntilSettled()

        model.toggle(model.items[0], enabled: false)
        await model.waitUntilSettled()

        // The failure marks the helper unreachable and says so.
        #expect(recorder.calls == [ApplyCall(itemID: "d", enabled: false)])
        #expect(model.helperUnreachable)
        #expect(model.notice?.message != nil)
        #expect(model.items[0].isEnabled)   // the switch snapped back

        // The next toggle routes through the install flow instead of
        // failing the same way.
        model.toggle(model.items[0], enabled: false)
        await model.waitUntilSettled()
        #expect(model.pendingChange != nil)

        // Confirming reinstalls, clears the mark, and applies the change
        // — this time the daemon answers.
        model.confirmPendingChange()
        await model.waitUntilSettled()
        #expect(!model.helperUnreachable)
        #expect(model.items[0].isEnabled == false)
    }

    /// A daemon that starts unreachable and answers once the reinstall
    /// has run — the shape of the broken-install repair.
    private final class PhaseFake: @unchecked Sendable {
        private let lock = NSLock()
        private var daemonAnswers = false

        var reachable: Bool {
            lock.lock()
            defer { lock.unlock() }
            return daemonAnswers
        }

        func makeReachable() {
            lock.lock()
            daemonAnswers = true
            lock.unlock()
        }
    }

    @Test func removingTheHelperIsConfirmedFirst() async {
        let (model, _, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .installed(version: "1.2.3")
        )
        model.activate()
        await model.waitUntilSettled()

        // The status row's action only opens the confirmation.
        model.requestHelperRemoval()
        #expect(model.isConfirmingHelperRemoval)
        #expect(model.helperState.isInstalled)

        // Cancelling changes nothing.
        model.cancelHelperRemoval()
        #expect(!model.isConfirmingHelperRemoval)
        #expect(model.helperState.isInstalled)

        // Confirming removes it and refreshes the state.
        model.requestHelperRemoval()
        model.removeHelper()
        await model.waitUntilSettled()
        #expect(!model.isConfirmingHelperRemoval)
        #expect(!model.helperState.isInstalled)
        #expect(model.notice?.message != nil)
        #expect(model.notice?.isError == false)
    }

    // MARK: Helper removal when the daemon does not answer

    @Test func anUnreachableHelperIsRemovedThroughElevation() async {
        // Files on disk, daemon dead: the XPC uninstall cannot run, and
        // the files are root-owned, so the removal elevates a one-shot
        // run of the bundled helper — the same password-gated path the
        // install uses — instead of dead-ending on a lost connection.
        let (model, _, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .installed(version: "1.2.3"),
            uninstall: { .failed("connection lost", unreachable: true) },
            uninstallElevated: { .succeeded }
        )
        model.activate()
        await model.waitUntilSettled()

        model.requestHelperRemoval()
        model.removeHelper()
        await model.waitUntilSettled()

        #expect(!model.helperState.isInstalled)
        #expect(model.notice?.isError == false)
        #expect(!model.isRemovingHelper)
    }

    @Test func aCancelledElevatedRemovalKeepsTheHelperAndIsNotAnError() async {
        let (model, _, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .installed(version: "1.2.3"),
            uninstall: { .failed("connection lost", unreachable: true) },
            uninstallElevated: { .cancelled }
        )
        model.activate()
        await model.waitUntilSettled()

        model.requestHelperRemoval()
        model.removeHelper()
        await model.waitUntilSettled()

        // The user dismissed the password dialog: nothing was removed,
        // and the helper is still there to try again with.
        #expect(model.helperState.isInstalled)
        #expect(model.notice?.isError == false)
    }

    @Test func aFailedElevatedRemovalNamesItsCause() async {
        let (model, _, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .installed(version: "1.2.3"),
            uninstall: { .failed("connection lost", unreachable: true) },
            uninstallElevated: { .failed("could not remove /Library/LaunchDaemons/cn.mingcui.mackit.helper.plist") }
        )
        model.activate()
        await model.waitUntilSettled()

        model.requestHelperRemoval()
        model.removeHelper()
        await model.waitUntilSettled()

        #expect(model.helperState.isInstalled)
        #expect(model.notice?.isError == true)
        #expect(model.notice?.message.contains("could not remove") == true)
    }

    @Test func aReachableUninstallNeverAsksForAPassword() async {
        // The daemon answers: the removal goes through it alone. The
        // elevated fallback exists for the daemon that cannot answer,
        // and must not fire when it can.
        let (model, _, _) = makeModel(
            items: [item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)],
            helperState: .installed(version: "1.2.3"),
            uninstall: { .success },
            uninstallElevated: { .failed("elevation must not run") }
        )
        model.activate()
        await model.waitUntilSettled()

        model.requestHelperRemoval()
        model.removeHelper()
        await model.waitUntilSettled()

        #expect(!model.helperState.isInstalled)
        #expect(model.notice?.isError == false)
    }

    // MARK: Install sheet copy

    @Test func theInstallSheetModeNamesTheActualProblem() async {
        let daemon = item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)

        // Nothing installed: a first install.
        let (fresh, _, _) = makeModel(items: [daemon])
        fresh.activate()
        await fresh.waitUntilSettled()
        #expect(fresh.installMode == .install)

        // An older helper: an update, whether or not it also answers.
        let (stale, _, _) = makeModel(items: [daemon], helperState: .installed(version: "1.0.0"))
        stale.activate()
        await stale.waitUntilSettled()
        #expect(stale.installMode == .update)

        // A current helper whose daemon does not answer: a repair. The
        // copy must not claim a version problem that does not exist —
        // that is what sent users hunting for an update that was
        // already installed.
        let (silent, _, _) = makeModel(
            items: [daemon],
            apply: { _, _ in .failed("connection lost", unreachable: true) },
            helperState: .installed(version: "1.2.3")
        )
        silent.activate()
        await silent.waitUntilSettled()
        silent.toggle(silent.items[0], enabled: false)
        await silent.waitUntilSettled()
        #expect(silent.helperUnreachable)
        #expect(silent.installMode == .repair)
    }

    // MARK: Search and derived state

    @Test func searchFiltersTheVisibleGroups() async {
        let foo = MatchedApp(name: "Foo", path: "/Applications/Foo.app")
        let (model, _, _) = makeModel(items: [
            item("a", label: "com.foo.agent", enabled: true, app: foo),
            item("b", label: "com.bar.service", enabled: true)
        ])
        model.activate()
        await model.waitUntilSettled()

        #expect(model.visibleGroups.count == 2)
        model.searchText = "foo"
        #expect(model.visibleGroups.count == 1)
        #expect(model.visibleGroups[0].name == "Foo")
        model.searchText = "nothing"
        #expect(model.visibleGroups.isEmpty)
    }

    @Test func systemDaemonsAreReportedForTheHelperRow() async {
        let (withDaemon, _, _) = makeModel(items: [
            item("d", label: "com.docker.socket", enabled: true, kind: .systemDaemon)
        ])
        withDaemon.activate()
        await withDaemon.waitUntilSettled()
        #expect(withDaemon.hasSystemDaemons)

        let (withoutDaemon, _, _) = makeModel(items: [item("a", label: "com.a", enabled: true)])
        withoutDaemon.activate()
        await withoutDaemon.waitUntilSettled()
        #expect(!withoutDaemon.hasSystemDaemons)
    }
}
