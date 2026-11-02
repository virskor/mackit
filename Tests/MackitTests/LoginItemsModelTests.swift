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
    private func makeModel(
        items: [LoginItem],
        apply: @escaping (LoginItem, Bool) async -> HelperOutcome = { _, _ in .success },
        helperState: HelperClient.InstalledState = .notInstalled,
        install: @escaping @Sendable () -> HelperInstaller.Outcome = { .installed }
    ) -> (LoginItemsModel, ApplyRecorder, HelperStateFake) {
        let recorder = ApplyRecorder()
        let state = HelperStateFake(helperState)
        let model = LoginItemsModel(
            scan: { items },
            apply: { item, enabled in
                recorder.record(item.id, enabled)
                return await apply(item, enabled)
            },
            readHelperState: { state.read() },
            // A successful install leaves the helper on disk; the fake
            // records that, exactly as the real install's files would.
            installHelper: {
                let outcome = install()
                if case .installed = outcome {
                    state.markInstalled(version: "1.2.3")
                }
                return outcome
            },
            uninstallHelper: {
                // The daemon removes its own files as root; the fake
                // records that, exactly as the real uninstall would.
                state.markRemoved()
                return .success
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

    // MARK: Scan lifecycle

    @Test func activateScansOncePerSession() async {
        let (model, _, _) = makeModel(items: [item("a", label: "com.a", enabled: true)])
        model.activate()
        await model.waitUntilSettled()
        #expect(model.hasScanned)
        #expect(model.items.count == 1)
        #expect(model.groups.count == 1)

        // A second visit is instant: no rescan.
        model.activate()
        await model.waitUntilSettled()
        #expect(model.items.count == 1)
    }

    @Test func rescanReplacesTheList() async {
        let (model, _, _) = makeModel(items: [item("a", label: "com.a", enabled: true)])
        model.activate()
        await model.waitUntilSettled()
        model.rescan()
        await model.waitUntilSettled()
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
            install: { .installed }
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
                return .installed
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
