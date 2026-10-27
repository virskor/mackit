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

    /// The file reveal selects the file through an AppleEvent to Finder, and
    /// an unpermitted target gets silence rather than an error — so the probe
    /// gates it. A bundle id that cannot name a running application is the
    /// deterministic direction of that gate: the target never resolves, so
    /// the answer is a no whatever the machine's Finder state is. (The
    /// permitted direction — Finder running, consent granted — was verified
    /// by hand on a real machine and cannot be asserted portably.)
    @Test func automationProbeDeclinesATargetThatCannotBeRunning() {
        #expect(RevealInFinder.canAutomate("com.example.noSuchApplication") == false)
    }
}
