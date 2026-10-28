import Foundation
import Testing

@testable import Mackit

/// The reveal decision is LaunchServices', not ours, and getting it wrong
/// starts an application the user only asked to see: a directory whose
/// extension marks it as an application is opened by the app itself.
struct RevealInFinderTests {
    @Test func applicationBundlesAreNeverOpenedDirectly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reveal-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // A directory with an .app extension is enough for LaunchServices to
        // call it an application and claim it for itself.
        let bundle = base.appendingPathComponent("Fake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        #expect(!RevealInFinder.opensDirectly(bundle), "an application bundle would launch the app")
    }

    @Test func plainFoldersOpenDirectly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("reveal-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(RevealInFinder.opensDirectly(base), "a plain folder is shown by Finder itself")
    }

    /// A permitted target is the everyday case: the reveal sends the event and
    /// Finder comes forward with the item selected.
    @Test func grantedAutomationSelects() {
        #expect(RevealInFinder.decision(for: .granted) == .select)
    }

    /// Never asked is the one direction that asks, because the dialog is what
    /// creates the system's answer — and it is asked at most once, since the
    /// answer is recorded and the next reveal goes straight to select or
    /// fallback.
    @Test func neverAskedRequestsConsentThenSelects() {
        #expect(RevealInFinder.decision(for: .notRequested) == .requestThenSelect)
    }

    /// A recorded refusal degrades to the permission-free fallback instead of
    /// asking again on every click.
    @Test func recordedRefusalOpensWithoutSelecting() {
        #expect(RevealInFinder.decision(for: .notGranted) == .openWithoutSelecting)
    }

    /// The target is not running is the one direction the probe cannot answer,
    /// and it still sends: with consent on record the event launches Finder
    /// and selects. (The permitted direction of that — and of the ask itself —
    /// was verified by hand on a real machine and cannot be asserted
    /// portably.)
    @Test func undeterminedAutomationStillSelects() {
        #expect(RevealInFinder.decision(for: .undetermined) == .select)
    }

    /// The administrator-authorization answer cannot occur for an automation
    /// target; there is nothing to request up front, so it degrades like a
    /// refusal.
    @Test func onDemandDegradesToOpeningWithoutSelecting() {
        #expect(RevealInFinder.decision(for: .onDemand) == .openWithoutSelecting)
    }
}
