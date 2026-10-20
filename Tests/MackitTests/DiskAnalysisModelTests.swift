import Foundation
import Testing

@testable import Mackit

/// Navigation, streaming, selection and cache behavior of the disk analysis
/// page's state model. The fixture mirrors the analyzer's: a small tree with
/// known sizes, so "select the largest child" and the size ordering are
/// deterministic.
@MainActor
struct DiskAnalysisModelTests {
    private func write(size: Int, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: size).write(to: url)
    }

    /// Sizes are chosen so the ordering is unambiguous: big ≈ 4 MB,
    /// root.bin = 2 MB, small = 1 KB — and inside big, nested (2 MB) beats
    /// a.bin / b.bin (1 MB each), so "select the largest child" is
    /// deterministic rather than a coin flip among equals.
    private func makeFixture() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-disk-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let mb = 1024 * 1024
        try write(size: mb, at: base.appendingPathComponent("big/a.bin"))
        try write(size: mb, at: base.appendingPathComponent("big/b.bin"))
        try write(size: 2 * mb, at: base.appendingPathComponent("big/nested/c.bin"))
        try write(size: 1024, at: base.appendingPathComponent("small/d.bin"))
        try write(size: 2 * mb, at: base.appendingPathComponent("root.bin"))
        return base
    }

    @Test func firstActivationScansTheRootAndSelectsTheLargest() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)

        model.activate()
        // Scanning starts synchronously, so the UI can show progress on the
        // very frame the page appears.
        #expect(model.isMeasuring)

        await model.waitUntilSettled()
        #expect(model.breadcrumb.count == 1)
        #expect(model.breadcrumb.first?.path == fixture.path)
        #expect(model.children.map(\.name) == ["big", "root.bin", "small"])
        #expect(model.children.allSatisfy { $0.size > 0 })
        // The largest child is auto-selected so the treemap has a subject
        // without a second click.
        #expect(model.selectedEntry?.name == "big")
        #expect(model.selectedChildren.count == 3)
        #expect(!model.isMeasuringSelection)
        #expect(!model.canGoBack)
        #expect(!model.canGoForward)
    }

    @Test func enteringDrillsDownAndHistoryWalksBackAndForward() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        await model.waitUntilSettled()

        model.enter(model.children[0])
        await model.waitUntilSettled()
        #expect(model.breadcrumb.count == 2)
        #expect(model.breadcrumb.last?.name == "big")
        #expect(Set(model.children.map(\.name)) == ["a.bin", "b.bin", "nested"])
        // Entering selects the largest child — nested at 2 MB — so the
        // treemap has a folder as its subject.
        #expect(model.selectedEntry?.name == "nested")
        #expect(model.selectedChildren.map(\.name) == ["c.bin"])
        #expect(model.canGoBack)
        #expect(!model.canGoForward)

        model.goBack()
        await model.waitUntilSettled()
        #expect(model.breadcrumb.count == 1)
        #expect(model.children.map(\.name) == ["big", "root.bin", "small"])
        #expect(model.canGoForward)
        #expect(!model.canGoBack)

        model.goForward()
        await model.waitUntilSettled()
        #expect(model.breadcrumb.count == 2)
        #expect(model.breadcrumb.last?.name == "big")
    }

    @Test func breadcrumbJumpTruncatesHistory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        await model.waitUntilSettled()

        model.enter(model.children[0])
        await model.waitUntilSettled()
        let nested = model.children.first { $0.name == "nested" }!
        model.enter(nested)
        await model.waitUntilSettled()
        #expect(model.breadcrumb.count == 3)

        model.navigateToBreadcrumb(index: 1)
        #expect(model.breadcrumb.count == 2)
        #expect(model.breadcrumb.last?.name == "big")
        // Jumping through the breadcrumb discards the forward history, same
        // as Safari: the path taken is gone.
        #expect(!model.canGoForward)
    }

    @Test func cachedDirectoryRestoresWithoutMeasuring() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        await model.waitUntilSettled()
        let big = model.children[0]

        model.enter(big)
        await model.waitUntilSettled()
        model.goBack()
        await model.waitUntilSettled()

        // Second visit: the cached listing restores synchronously — no
        // measurement pass, no empty-list flicker.
        model.enter(big)
        #expect(!model.isMeasuring)
        #expect(model.children.count == 3)
        #expect(!model.isMeasuringSelection)
        #expect(model.selectedChildren.map(\.name) == ["c.bin"])
        #expect(model.selectedEntry?.name == "nested")
    }

    @Test func selectingAFileShowsNoChildren() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        await model.waitUntilSettled()

        let file = model.children.first { $0.name == "root.bin" }!
        model.select(file.id)
        await model.waitUntilSettled()
        #expect(model.selectedEntry?.name == "root.bin")
        #expect(model.selectedChildren.isEmpty)
        #expect(!model.isMeasuringSelection)
    }

    /// The toolbar's home shortcut: one click from the disk root to the home
    /// folder, skipping the intermediate levels (their breadcrumb entries are
    /// synthesized — names only — and get measured when entered).
    @Test func goToHomeJumpsStraightToTheHomeFolder() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        // 64 KB, comfortably above the filesystem block size: a 4 KB file
        // allocates the same block as small's 1 KB, and equal sizes make the
        // size-descending order depend on measurement completion order.
        try write(size: 64 * 1024, at: fixture.appendingPathComponent("home/notes.txt"))
        let model = DiskAnalysisModel(
            rootPath: fixture.path,
            homePath: fixture.appendingPathComponent("home").path
        )
        model.activate()
        await model.waitUntilSettled()
        #expect(model.children.map(\.name) == ["big", "root.bin", "home", "small"])

        model.goToHome()
        await model.waitUntilSettled()
        #expect(model.breadcrumb.count == 2)
        #expect(model.breadcrumb.last?.name == "home")
        #expect(model.children.map(\.name) == ["notes.txt"])
        #expect(model.canGoBack)

        // Jumping while already home is a no-op, not a history entry.
        let history = model.breadcrumb
        model.goToHome()
        #expect(model.breadcrumb == history)
    }

    /// The home's TCC-protected folders are listed but not measured, so no
    /// access dialog fires mid-scan. Their rows say "not scanned"; entering
    /// one routes to a selection instead of navigating (there is nothing to
    /// show yet), and an explicit scan promotes the row to measured.
    @Test func protectedHomeFoldersAreSkippedUntilScannedOnRequest() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home")
        try write(size: 64 * 1024, at: home.appendingPathComponent("Documents/report.pdf"))
        try write(size: 32 * 1024, at: home.appendingPathComponent("Desktop/shot.png"))
        try write(size: 4096, at: home.appendingPathComponent("notes.txt"))

        let model = DiskAnalysisModel(rootPath: fixture.path, homePath: home.path)
        model.goToHome()
        await model.waitUntilSettled()

        let documents = model.children.first { $0.name == "Documents" }
        #expect(documents?.isSkipped == true, "Documents must be listed as skipped")
        #expect(documents?.size == 0, "a skipped folder is never measured")
        // Desktop is skipped too; the plain files are measured normally.
        #expect(model.children.first { $0.name == "Desktop" }?.isSkipped == true)
        #expect(model.children.first { $0.name == "notes.txt" }?.isMeasured == true)

        // Double-clicking a skipped row does not navigate — it selects, so
        // the detail can explain and offer the explicit scan.
        model.enter(documents!)
        #expect(model.breadcrumb.count == 2, "a skipped folder is not entered")
        #expect(model.selectedEntry?.name == "Documents")

        // The explicit scan measures it and promotes the row.
        model.scanSkippedFolder(documents!)
        await model.waitUntilSettled()
        #expect(model.selectedChildren.map(\.name) == ["report.pdf"])
        let promoted = model.children.first { $0.name == "Documents" }
        #expect(promoted?.isSkipped == false, "the row is promoted after scanning")
        #expect(promoted?.isMeasured == true)
        #expect(promoted?.size ?? 0 >= 64 * 1024)

        // With the folder approved, entering it navigates normally now.
        model.enter(promoted!)
        await model.waitUntilSettled()
        #expect(model.breadcrumb.last?.name == "Documents")
        #expect(model.children.map(\.name) == ["report.pdf"])
    }

    /// A row's double-click fires the button's select *after* the enter
    /// gesture, and that stale id — the folder just entered, no longer among
    /// its own children — must not dangle as a selection: it would blank the
    /// treemap the auto-selection had just filled.
    @Test func selectingAnIdOutsideTheListingIsIgnored() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        await model.waitUntilSettled()

        let big = model.children[0]
        model.enter(big)
        await model.waitUntilSettled()
        #expect(model.selectedEntry?.name == "nested")

        model.select(big.id)
        #expect(model.selectedEntry?.name == "nested", "a stale select must not replace the selection")
        #expect(model.selectedChildren.map(\.name) == ["c.bin"])
    }

    @Test func stopClearsTheMeasuringFlags() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        #expect(model.isMeasuring)

        model.rescanOrStop()
        #expect(!model.isMeasuring, "stop must clear the flags or the toolbar stays on Stop forever")
        #expect(!model.isMeasuringSelection)
    }

    @Test func suspendThenActivateResumesTheScan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        model.suspend()
        #expect(!model.isMeasuring)

        model.activate()
        await model.waitUntilSettled()
        #expect(model.children.count == 3)
    }

    @Test func unreadableDirectoryIsFlaggedInsteadOfLookingEmpty() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let locked = fixture.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        await model.waitUntilSettled()

        let entry = model.children.first { $0.name == "locked" }!
        model.enter(entry)
        #expect(model.unreadable)
        #expect(model.children.isEmpty)
        #expect(!model.isMeasuring)
    }
}
