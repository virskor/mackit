import Foundation
import Testing

@testable import Mackit

/// The launch-agent toggle's verdict logic.
///
/// `launchctl enable` and `launchctl disable` exit zero even for a label
/// that names no service — verified against a live launchd — so the exit
/// status cannot be the verdict on whether the override landed. The
/// action reads the recorded state back from launchd's own dump, and
/// these tests pin that verdict to the dump rather than to the exit
/// status.
@MainActor
struct LoginItemActionsTests {
    /// A user agent whose label and plist are the ones the canned
    /// launchctl answers for.
    private func item(label: String = "com.example.foo") -> LoginItem {
        LoginItem(
            id: "/tmp/\(label).plist",
            kind: .userAgent,
            label: label,
            plistPath: "/tmp/\(label).plist",
            targetPath: nil,
            app: nil,
            isEnabled: false
        )
    }

    /// A canned launchctl. `disabledDump` is what `print-disabled`
    /// answers; `loaded` decides the `print` probe; nil from any of them
    /// is the runner's failure answer.
    private func runner(
        overrideAnswer: String? = "ok",
        disabledDump: String? = nil,
        loaded: Bool = false,
        session: String? = "ok"
    ) -> LaunchctlRun {
        { arguments in
            switch arguments.first {
            case "enable", "disable":
                return overrideAnswer
            case "print-disabled":
                return disabledDump
            case "print":
                return loaded ? "state = running" : nil
            case "bootstrap", "bootout":
                return session
            default:
                return nil
            }
        }
    }

    /// The happy path: the override lands, the service is not loaded, so
    /// the bootstrap brings the session in line.
    @Test func enableSucceedsWhenTheOverrideIsRecorded() async throws {
        let outcome = await LoginItemActions.setEnabled(
            item(),
            enabled: true,
            launchctl: runner(disabledDump: "\"com.example.foo\" => enabled")
        )
        #expect(outcome.succeeded, "got \(outcome.failure ?? "nil")")
    }

    /// launchctl exited zero but the dump holds no record for the label:
    /// the override never landed, which is the no-op the exit status
    /// cannot see.
    @Test func enableFailsWhenTheOverrideIsNotRecorded() async throws {
        let outcome = await LoginItemActions.setEnabled(
            item(),
            enabled: true,
            launchctl: runner(disabledDump: "disabled services = {\n}")
        )
        #expect(!outcome.succeeded)
    }

    /// The dump records the opposite state: the command's effect and the
    /// recorded state disagree, so the run is reported as the failure it
    /// is rather than a success.
    @Test func enableFailsWhenTheRecordDisagrees() async throws {
        let outcome = await LoginItemActions.setEnabled(
            item(),
            enabled: true,
            launchctl: runner(disabledDump: "\"com.example.foo\" => disabled")
        )
        #expect(!outcome.succeeded)
    }

    /// A dump that cannot be read at all is a failure, not a pass: the
    /// verdict is unverifiable, and an unverifiable override must not
    /// read as done.
    @Test func enableFailsWhenTheDumpCannotBeRead() async throws {
        let outcome = await LoginItemActions.setEnabled(
            item(),
            enabled: true,
            launchctl: runner(disabledDump: nil)
        )
        #expect(!outcome.succeeded)
    }

    /// The override command itself failing is still a failure.
    @Test func enableFailsWhenTheOverrideCommandFails() async throws {
        let outcome = await LoginItemActions.setEnabled(
            item(),
            enabled: true,
            launchctl: runner(overrideAnswer: nil, disabledDump: "\"com.example.foo\" => enabled")
        )
        #expect(!outcome.succeeded)
    }

    /// The disable path's happy end: the record says disabled, the
    /// service is loaded, the bootout tears it down.
    @Test func disableSucceedsWhenTheOverrideIsRecorded() async throws {
        let outcome = await LoginItemActions.setEnabled(
            item(),
            enabled: false,
            launchctl: runner(disabledDump: "\"com.example.foo\" => disabled", loaded: true)
        )
        #expect(outcome.succeeded, "got \(outcome.failure ?? "nil")")
    }

    /// Disabling a service that is not loaded stops after the override:
    /// there is nothing to tear down, and the record confirms the state.
    @Test func disableOfAnUnloadedServiceStopsAfterTheOverride() async throws {
        let outcome = await LoginItemActions.setEnabled(
            item(),
            enabled: false,
            launchctl: runner(disabledDump: "\"com.example.foo\" => disabled", loaded: false)
        )
        #expect(outcome.succeeded, "got \(outcome.failure ?? "nil")")
    }

    /// The record still says enabled after a disable: the operation did
    /// not take, whatever the exit status was.
    @Test func disableFailsWhenTheRecordDisagrees() async throws {
        let outcome = await LoginItemActions.setEnabled(
            item(),
            enabled: false,
            launchctl: runner(disabledDump: "\"com.example.foo\" => enabled", loaded: true)
        )
        #expect(!outcome.succeeded)
    }

    /// The label is matched as a whole token: another label that merely
    /// contains it must not vouch for the override.
    @Test func aContainingLabelDoesNotVouchForTheOverride() async throws {
        let outcome = await LoginItemActions.setEnabled(
            item(label: "com.example.foo"),
            enabled: true,
            launchctl: runner(disabledDump: "\"com.example.foo.helper\" => enabled")
        )
        #expect(!outcome.succeeded)
    }

    /// A loaded service needs no bootstrap when enabled: the override
    /// alone is the whole change, and the run still succeeds.
    @Test func enablingALoadedServiceSkipsTheBootstrap() async throws {
        let outcome = await LoginItemActions.setEnabled(
            item(),
            enabled: true,
            launchctl: runner(disabledDump: "\"com.example.foo\" => enabled", loaded: true)
        )
        #expect(outcome.succeeded, "got \(outcome.failure ?? "nil")")
    }
}
