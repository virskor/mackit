import Foundation
import Testing

@testable import Mackit

/// The probes the permissions section renders.
///
/// What can be asserted portably is split from what cannot: the probe logic
/// and the automation probe's deterministic direction are pinned here, while
/// whether Full Disk Access or an automation consent happens to be granted is
/// the machine's own state. The ungated directions were measured on a real
/// machine (0 of 44 third-party apps under /Applications resolved a launch
/// date without Full Disk Access); the tests below never depend on them.
struct AppPermissionsTests {
    /// The probe only trusts an installed bundle: the gating the Spotlight
    /// signal was measured against applies to /Applications, and a build
    /// running from DerivedData would read its own record either way.
    /// ~/Applications is excluded with them — unmeasured, not assumed.
    @Test func probeOutsideApplicationsIsUndetermined() {
        #expect(AppPermissions.fullDiskAccess(bundlePath: "/Users/me/build/Debug/Mackit") == .undetermined)
        #expect(AppPermissions.fullDiskAccess(bundlePath: "/Users/me/Applications/Mackit.app") == .undetermined)
    }

    /// An installed bundle whose own launch record resolves — the app is
    /// running, so it has one — means the record is readable, which is the
    /// grant.
    @Test func readableLaunchRecordMeansGranted() {
        #expect(AppPermissions.fullDiskAccess(
            bundlePath: "/Applications/Mackit.app",
            lastOpened: { _ in Date() }
        ) == .granted)
    }

    /// An installed bundle with no readable launch record: the ungated
    /// direction was measured on a real machine (third-party records all read
    /// nil without Full Disk Access), so nil is the refusal.
    @Test func missingLaunchRecordMeansNotGranted() {
        #expect(AppPermissions.fullDiskAccess(
            bundlePath: "/Applications/Mackit.app",
            lastOpened: { _ in nil }
        ) == .notGranted)
    }

    /// The real probe in a test run answers "could not tell" rather than
    /// guessing: the test bundle never lives under /Applications, and the one
    /// thing the probe must never do is invent a permission state.
    @Test func realProbeNeverInventsAState() {
        #expect(AppPermissions.fullDiskAccess() == .undetermined)
    }

    /// A bundle id that cannot name a running application is the
    /// deterministic direction of the automation probe: the target never
    /// resolves (`procNotFound`, the status a real machine returned for an
    /// app that was not running), so the answer is "undetermined" whatever
    /// the machine's Finder state is.
    @Test func automationProbeOfAnAbsentTargetIsUndetermined() {
        #expect(AppPermissions.automation("com.example.noSuchApplication") == .undetermined)
    }

    /// The return-code mapping is the contract with Apple's header: the three
    /// live answers were verified on a real machine (noErr for a permitted
    /// running target, errAEEventWouldRequireUserConsent for a running target
    /// this app never asked about, procNotFound for a target that is not
    /// running), and a recorded refusal — or any other failure — must read as
    /// "the system holds an answer", never as "never asked" (which would send
    /// the user to a request the system will not show).
    @Test func automationAnswerMappingFollowsTheHeader() {
        #expect(AppPermissions.status(ofAutomationStatus: noErr) == .granted)
        #expect(AppPermissions.status(ofAutomationStatus: OSStatus(procNotFound)) == .undetermined)
        #expect(AppPermissions.status(ofAutomationStatus: OSStatus(errAEEventWouldRequireUserConsent)) == .notRequested)
        #expect(AppPermissions.status(ofAutomationStatus: OSStatus(errAEEventNotPermitted)) == .notGranted)
        #expect(AppPermissions.status(ofAutomationStatus: OSStatus(-1)) == .notGranted)
    }

    /// The reveal's gate stays a plain yes/no on top of the three-way probe:
    /// "could not tell" must read as no there, because the reveal has a
    /// working permission-free fallback for it.
    @Test func revealGateTreatsUndeterminedAsNo() {
        #expect(RevealInFinder.canAutomate("com.example.noSuchApplication") == false)
    }
}
