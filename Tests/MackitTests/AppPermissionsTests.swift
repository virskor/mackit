import Foundation
import Testing

@testable import Mackit

/// The probes the permissions section renders.
///
/// The machine's own grants are not something a test run may depend on, so
/// the Full Disk Access probe is pinned through its seam: what matters is the
/// mapping (a readable protected folder is the grant, a refused one is its
/// absence, no folder at all is "could not tell") and the fall-through
/// between candidates. The automation probe's deterministic directions are
/// pinned the same way.
struct AppPermissionsTests {
    /// Answers only for the paths the test names; everything else is a folder
    /// the account does not have.
    private func probe(
        _ answers: [String: AppPermissions.DirectoryAccess]
    ) -> (String) -> AppPermissions.DirectoryAccess {
        { answers[$0] ?? .missing }
    }

    private let home = "/Users/me"

    private func candidate(_ name: String) -> String {
        "\(home)/Library/\(name)"
    }

    /// A protected folder that opens is the grant.
    @Test func readableProtectedFolderMeansGranted() {
        #expect(AppPermissions.fullDiskAccess(
            homeDirectory: home,
            probe: probe([candidate("Safari"): .readable])
        ) == .granted)
    }

    /// A protected folder that exists and refuses is the missing grant.
    @Test func refusedProtectedFolderMeansNotGranted() {
        #expect(AppPermissions.fullDiskAccess(
            homeDirectory: home,
            probe: probe([candidate("Safari"): .denied])
        ) == .notGranted)
    }

    /// A folder the account never created says nothing about the permission:
    /// the probe moves on to the next candidate.
    @Test func absentFoldersFallThroughToTheNextCandidate() {
        #expect(AppPermissions.fullDiskAccess(
            homeDirectory: home,
            probe: probe([
                candidate("Safari"): .missing,
                candidate("Mail"): .readable,
            ])
        ) == .granted)
    }

    /// A refusal is the answer even if a later candidate would read: the
    /// candidates are all gated by the same permission, so the first one that
    /// exists and refuses settles it.
    @Test func refusalStopsTheProbe() {
        #expect(AppPermissions.fullDiskAccess(
            homeDirectory: home,
            probe: probe([
                candidate("Safari"): .denied,
                candidate("Mail"): .readable,
            ])
        ) == .notGranted)
    }

    /// None of the candidates exists: the probe says "could not tell" rather
    /// than inventing either answer.
    @Test func noExistingCandidateIsUndetermined() {
        #expect(AppPermissions.fullDiskAccess(
            homeDirectory: home,
            probe: probe([:])
        ) == .undetermined)
    }

    /// The primitive behind the probe reads a directory the process owns and
    /// reports a nonexistent path as missing. The refusal a real protected
    /// folder produces without the grant is pinned below with a mode-000
    /// directory, which yields the same EACCES.
    @Test func directoryProbeDistinguishesReadableAndMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(AppPermissions.probeDirectory(at: directory.path) == .readable)
        #expect(AppPermissions.probeDirectory(at: "/definitely/not/here/\(UUID().uuidString)") == .missing)
    }

    /// A symlink standing in for a directory must not answer for it; the
    /// probe treats it as unusable and tries the next candidate.
    @Test func symlinkAtAProtectedPathIsNotReadable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-probe-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(AppPermissions.probeDirectory(at: link.path) == .missing)
    }

    /// A directory the process may not read is a refusal — the answer that
    /// separates "the grant is missing" from "no folder here". A mode-000
    /// directory the test owns produces the same EACCES a protected folder
    /// produces without the grant, so the classification is pinned without
    /// depending on the machine's own grants.
    @Test func directoryProbeClassifiesAPermissionRefusalAsDenied() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            // The permissions come back before the cleanup: a 0o700 directory
            // is what removal expects to walk into.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)

        #expect(AppPermissions.probeDirectory(at: directory.path) == .denied)
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
}
