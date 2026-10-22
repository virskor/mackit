import Foundation
import ServiceManagement
import Testing

@testable import Mackit

/// The launch-at-login registration's self-healing decisions.
///
/// The system side (SMAppService, launchd, the kernel's launch-constraint check)
/// is not reachable from a test, so what is covered here is the decision function:
/// given a registration state and the binary the registration was built from, does
/// it need rebuilding? Every branch below corresponds to a state observed on a real
/// machine.
struct LaunchAtLoginTests {
    /// A registration built from the binary that is on disk right now is exactly
    /// what the system expects — leave it alone.
    @Test func healthyRegistrationIsLeftAlone() {
        #expect(!LaunchAtLogin.needsRepair(
            status: .enabled,
            currentCdHash: "ac1ad533",
            registeredCdHash: "ac1ad533"
        ))
    }

    /// The case the whole mechanism exists for: the registration still reads as
    /// enabled, but the agent binary its constraint pins was replaced, so every
    /// login is killed with a launch-constraint violation until it is rebuilt.
    @Test func registrationBuiltFromReplacedBinaryIsRebuilt() {
        #expect(LaunchAtLogin.needsRepair(
            status: .enabled,
            currentCdHash: "ac1ad533",
            registeredCdHash: "0d1a44ff"
        ))
    }

    /// First launch under this mechanism records nothing yet, and an existing
    /// registration can only predate it — rebuild once and record.
    @Test func registrationWithoutRecordIsRebuilt() {
        #expect(LaunchAtLogin.needsRepair(
            status: .enabled,
            currentCdHash: "ac1ad533",
            registeredCdHash: nil
        ))
    }

    /// launchd removes a service whose launch constraint kept failing; the entry
    /// left behind resolves to no bundle at all, so the item has to be registered
    /// again from scratch.
    @Test func missingRegistrationIsRebuilt() {
        #expect(LaunchAtLogin.needsRepair(status: .notRegistered, currentCdHash: "ac1ad533", registeredCdHash: nil))
        #expect(LaunchAtLogin.needsRepair(status: .notFound, currentCdHash: "ac1ad533", registeredCdHash: nil))
    }

    /// The user still has to approve the item in System Settings; rebuilding
    /// changes nothing about that, so it must not churn the registration on
    /// every launch.
    @Test func approvalPendingIsLeftAlone() {
        #expect(!LaunchAtLogin.needsRepair(
            status: .requiresApproval,
            currentCdHash: "ac1ad533",
            registeredCdHash: nil
        ))
    }

    /// The persisted intent is what the app acts on — it survives a registration
    /// the system gave up on, which is the point of persisting it.
    @Test @MainActor func persistedIntentIsReadFromSettings() {
        #expect(LaunchAtLogin.preferredIntent(from: ["launchAtLogin": true]))
        #expect(!LaunchAtLogin.preferredIntent(from: ["launchAtLogin": false]))
    }

    /// Settings files written before the intent was persisted have no key; they
    /// keep reading the system registration, as the older versions did.
    @Test @MainActor func intentFallsBackToSystemStateWhenNeverPersisted() {
        #expect(LaunchAtLogin.preferredIntent(from: [:]) == LaunchAtLogin.isEnabled)
    }

    /// The test host has no embedded agent, so there is no binary to read a hash
    /// from — and the repair must decline to run rather than record a nil hash
    /// that would look like a rebuild on the next launch.
    @Test @MainActor func repairDeclinesWhenNoAgentBinaryIsEmbedded() async {
        let suiteName = "LaunchAtLoginTests.noAgent"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)

        let rebuilt = try? await LaunchAtLogin.repairIfNeeded(
            preferred: true,
            currentCdHash: nil,
            defaults: suite
        )

        #expect(rebuilt == false)
        #expect(suite.string(forKey: LaunchAtLogin.registeredCdHashKey) == nil)
    }
}
