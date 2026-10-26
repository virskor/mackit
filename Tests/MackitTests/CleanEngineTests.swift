import Foundation
import Testing

@testable import Mackit

/// The clean engine's safety and reclaimed-amount calculation.
///
/// All targets are constructed via temporary directories, never touching the
/// real ~/Library; the protected path cases take the "reject on prefix"
/// branch and never hit disk at all.
struct CleanEngineTests {
    private func tempDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-clean-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(
        _ path: String,
        size: Int64 = 0,
        bundleID: String? = nil,
        appKind: AppItemKind? = nil,
        appName: String? = nil,
        holdsLiveAppData: Bool = false,
        category: JunkCategory = .system
    ) -> JunkItem {
        JunkItem(
            ruleID: "test.rule",
            title: (path as NSString).lastPathComponent,
            detail: "Test",
            path: path,
            category: category,
            risk: .safe,
            size: size,
            bundleID: bundleID,
            appKind: appKind,
            appName: appName,
            holdsLiveAppData: holdsLiveAppData
        )
    }

    /// Runs one clean pass, collecting all outcomes and the final summary.
    private func run(
        items: [JunkItem],
        moveToTrash: Bool = false,
        isAppRunning: @escaping @Sendable (String) -> Bool = { _ in false }
    ) async -> (outcomes: [CleanOutcome], reclaimed: Int64, failures: Int) {
        var outcomes: [CleanOutcome] = []
        var reclaimed: Int64 = 0
        var failures = 0
        let stream = CleanEngine.clean(
            items: items,
            moveToTrash: moveToTrash,
            isAppRunning: isAppRunning
        )
        for await event in stream {
            switch event {
            case .outcome(let outcome): outcomes.append(outcome)
            case .finished(let total, let count):
                reclaimed = total
                failures = count
            default: break
            }
        }
        return (outcomes, reclaimed, failures)
    }

    // MARK: - Protected paths

    @Test func protectedPathsAreRefusedWithoutTouchingDisk() async {
        // /Library/Apple is a protected prefix: no file is created here at
        // all; as long as the engine refuses it, removeItem will never be
        // called.
        let target = "/Library/Apple/mackit-should-never-exist-\(UUID().uuidString)"
        let (outcomes, reclaimed, failures) = await run(items: [item(target, size: 1024)])

        #expect(outcomes.count == 1)
        #expect(outcomes[0].succeeded == false, "protected paths must be refused")
        #expect(reclaimed == 0)
        #expect(failures == 1)
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    /// The protected-path check has to hold at the moment of the mutation, not
    /// only where the item was first vetted. Between the two the engine
    /// re-measures the entry — a recursive walk that takes seconds on a large
    /// cache — and anything with write permission on the parent can swap the
    /// entry in that window; `removeItem` would then delete whatever now sits
    /// at the path. `removeFromDisk` is the one place every removal funnels
    /// through, so the check lives there too.
    @Test func theProtectedCheckRunsAgainAtTheRemovalItself() async throws {
        // A nonexistent path keeps this off the real filesystem entirely: the
        // check compares spellings, so it never needs the entry to exist.
        let protected = "/Library/Apple/mackit-should-never-exist-\(UUID().uuidString)"
        let result = await CleanEngine.removeFromDisk(URL(fileURLWithPath: protected), moveToTrash: false)

        guard case .failed = result else {
            Issue.record("the removal seam accepted a protected path")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: protected))

        // A link whose target is protected is refused as well: the delete acts
        // on the resolved path, so the check has to resolve it too. The link
        // itself is the only thing at stake, and it survives.
        let base = tempDirectory("recheck")
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: URL(fileURLWithPath: "/Library/Apple")
        )
        let linkResult = await CleanEngine.removeFromDisk(link, moveToTrash: false)

        guard case .failed = linkResult else {
            Issue.record("the removal seam accepted a link into a protected directory")
            return
        }
        #expect(FileManager.default.fileExists(atPath: link.path), "the link itself survived")
    }

    // MARK: - Non-existent paths

    @Test func missingPathReportsSuccessWithZeroReclaimed() async {
        let dir = tempDirectory("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("already-gone").path

        // A file deleted elsewhere after the scan is routine: drop this entry
        // from the list, but count no reclaimed amount
        let (outcomes, reclaimed, _) = await run(items: [item(target, size: 4096)])

        #expect(outcomes[0].succeeded == true)
        #expect(outcomes[0].reclaimed == 0, "a non-existent path must not count toward the reclaimed amount")
        #expect(reclaimed == 0)
    }

    // MARK: - Reclaimed amount uses the actual deleted size

    @Test func reclaimedUsesFreshlyMeasuredSize() async throws {
        let dir = tempDirectory("fresh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("cache.bin")
        try Data(repeating: 0x41, count: 8192).write(to: target)

        let expected = FileSystem.allocatedSize(of: target)
        // The size may have changed after the scan: pass in a stale
        // outsized value; the reclaimed amount must be computed from what
        // was actually deleted
        let (outcomes, reclaimed, _) = await run(items: [item(target.path, size: 999_999_999)])

        #expect(outcomes[0].succeeded)
        #expect(outcomes[0].reclaimed == expected)
        #expect(reclaimed == expected)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// Nested rules (a parent directory + its subdirectory both checked) must
    /// not count the same space twice: when the parent is deleted first the
    /// child no longer exists (0 reclaimed); when the child is deleted first
    /// the parent is counted at its remaining size.
    @Test func nestedRulesDoNotDoubleCountReclaimed() async throws {
        for parentFirst in [true, false] {
            let dir = tempDirectory(parentFirst ? "nested-parent-first" : "nested-child-first")
            defer { try? FileManager.default.removeItem(at: dir) }

            let parent = dir.appendingPathComponent("parent", isDirectory: true)
            let child = parent.appendingPathComponent("child", isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

            var expected: Int64 = 0
            for name in ["a.bin", "child/b.bin", "child/c.bin"] {
                let url = parent.appendingPathComponent(name)
                try Data(repeating: 0x42, count: 4096).write(to: url)
                expected += FileSystem.allocatedSize(of: url)
            }

            let parentItem = item(parent.path, size: 999_999)
            let childItem = item(child.path, size: 999_999)
            let order = parentFirst ? [parentItem, childItem] : [childItem, parentItem]

            let (outcomes, reclaimed, failures) = await run(items: order)

            #expect(failures == 0)
            #expect(outcomes.count == 2)
            #expect(reclaimed == expected, "the same space was counted twice: \(reclaimed) vs \(expected)")
            #expect(!FileManager.default.fileExists(atPath: parent.path))
        }
    }

    // MARK: - Running apps

    /// The guard covers what deleting would actually break: the app's own
    /// bundle and residue that holds live data. Regenerable caches are
    /// deliberately exempt — an app rebuilds them on demand, so refusing them
    /// would only turn every clean into a list of failures for files the app
    /// does not need.
    @Test func runningAppRefusesBundleAndLiveDataOnly() async throws {
        let dir = tempDirectory("running")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = dir.appendingPathComponent("Foo.app", isDirectory: true)
        let prefs = dir.appendingPathComponent("com.example.foo.plist", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)

        let bundleItem = item(bundle.path, bundleID: "com.example.foo", appKind: .bundle, holdsLiveAppData: true)
        let prefsItem = item(prefs.path, bundleID: "com.example.foo", appKind: .residue(.preferences), holdsLiveAppData: true)

        let (outcomes, reclaimed, failures) = await run(
            items: [bundleItem, prefsItem],
            isAppRunning: { $0 == "com.example.foo" }
        )

        #expect(outcomes.allSatisfy { !$0.succeeded }, "a running app and its data residue must be refused")
        #expect(failures == 2)
        #expect(reclaimed == 0)
        #expect(FileManager.default.fileExists(atPath: bundle.path))
        #expect(FileManager.default.fileExists(atPath: prefs.path))
    }

    @Test func runningAppCacheIsStillCleaned() async throws {
        let dir = tempDirectory("running-cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("com.example.foo", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let cacheItem = item(
            cache.path,
            bundleID: "com.example.foo",
            appKind: .residue(.caches),
            appName: "Foo",
            category: .appJunk
        )

        let (outcomes, _, failures) = await run(
            items: [cacheItem],
            isAppRunning: { $0 == "com.example.foo" }
        )

        #expect(failures == 0, "a cache can be rebuilt at any time, so it can be cleaned while running")
        #expect(outcomes[0].succeeded)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func nonRunningAppIsCleanedNormally() async throws {
        let dir = tempDirectory("not-running")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Bar.app", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let (outcomes, _, failures) = await run(
            items: [item(target.path, bundleID: "com.example.bar", appKind: .bundle)],
            isAppRunning: { _ in false }
        )

        #expect(outcomes[0].succeeded)
        #expect(failures == 0)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - Command-line cleaning

    @Test func commandItemRunsAndReportsSizeHint() async {
        // /bin/echo always exists; the output is drained, exit code 0
        let commandItem = JunkItem(
            ruleID: "test.cli",
            title: "echo",
            detail: "Test",
            path: "",
            category: .system,
            risk: .safe,
            size: 2048,
            isCommand: true,
            command: ["/bin/echo", "hello"]
        )

        let (outcomes, reclaimed, failures) = await run(items: [commandItem])

        #expect(outcomes[0].succeeded)
        #expect(reclaimed == 2048, "a command item's reclaimed amount can only report the hint size measured at scan time")
        #expect(failures == 0)
    }

    @Test func failingCommandReportsFailure() async {
        let commandItem = JunkItem(
            ruleID: "test.cli",
            title: "false",
            detail: "Test",
            path: "",
            category: .system,
            risk: .safe,
            size: 0,
            isCommand: true,
            command: ["/usr/bin/false"]
        )

        let (outcomes, reclaimed, failures) = await run(items: [commandItem])

        #expect(outcomes[0].succeeded == false)
        #expect(reclaimed == 0)
        #expect(failures == 1)
    }

    // MARK: - Removal mode

    /// An entry already inside a Trash cannot be recycled: `NSWorkspace`
    /// reports success without moving it, which made "empty the Trash" delete
    /// nothing while reporting the bytes as freed. Those entries are deleted
    /// outright — that is what emptying the Trash means.
    ///
    /// The Trash root is injected, so the fixture is an ordinary temporary
    /// directory and the user's real Trash is never touched.
    @Test func entryAlreadyInTrashIsDeletedNotRecycled() async throws {
        let trash = tempDirectory("trash")
        defer { try? FileManager.default.removeItem(at: trash) }
        let entry = trash.appendingPathComponent("old.log")
        try Data(repeating: 0x41, count: 1024).write(to: entry)

        let result = await CleanEngine.removeFromDisk(entry, moveToTrash: true, trashDirectory: trash)

        #expect(result == .deleted)
        #expect(!FileManager.default.fileExists(atPath: entry.path), "the entry must actually be gone")
    }

    /// The permanent path outside a Trash removes the entry as well — the
    /// "move to Trash" setting is off here, which is every non-default clean.
    @Test func permanentRemovalDeletesTheEntry() async throws {
        let base = tempDirectory("permanent")
        defer { try? FileManager.default.removeItem(at: base) }
        let entry = base.appendingPathComponent("cache.bin")
        try Data(repeating: 0x42, count: 512).write(to: entry)

        let result = await CleanEngine.removeFromDisk(entry, moveToTrash: false)

        #expect(result == .deleted)
        #expect(!FileManager.default.fileExists(atPath: entry.path))
    }

    /// A path that cannot be removed reports a failure with a message instead
    /// of claiming success: the caller must never count bytes it did not free.
    @Test func unremovableEntryReportsFailureWithoutClaimingBytes() async throws {
        let base = tempDirectory("unremovable")
        defer { try? FileManager.default.removeItem(at: base) }
        let entry = base.appendingPathComponent("locked")
        try Data(repeating: 0x43, count: 16).write(to: entry)
        // A file inside the directory keeps the directory itself from being
        // removed only if the parent is made read-only; removing the parent's
        // write permission makes the child undeletable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: base.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path) }

        let result = await CleanEngine.removeFromDisk(entry, moveToTrash: false)

        if case .failed(let message) = result {
            #expect(!message.isEmpty, "a failure must carry something to show the user")
            #expect(FileManager.default.fileExists(atPath: entry.path), "the entry is still there, so nothing was freed")
        } else {
            // Root, or a filesystem that ignores the permission: the removal
            // succeeded, and then there is nothing to assert about failure.
            #expect(result == .deleted)
        }
    }
}
