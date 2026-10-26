import Foundation
import Testing

@testable import Mackit

/// Navigation, scan and selection behavior of the disk analysis page's state
/// model. The fixture mirrors the analyzer's: a small tree with known sizes,
/// so "select the largest child" and the size ordering are deterministic.
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

    /// Entering the page must not start a measurement on its own — a
    /// whole-disk traversal is minutes of IO the user did not ask for. The
    /// start screen's button is what starts it.
    @Test func activationDoesNotScanUntilTheUserStartsIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)

        model.activate()
        #expect(!model.isScanning, "entering the page must not start a scan")
        #expect(model.root == nil, "nothing is presented before the scan lands")

        model.startScan()
        // Scanning starts synchronously, so the UI can leave the start screen
        // on the very frame the button is pressed.
        #expect(model.isScanning)
        #expect(model.root == nil)

        await model.waitUntilSettled()
        #expect(model.breadcrumb.count == 1)
        #expect(model.breadcrumb.first?.path == fixture.path)
        #expect(model.children.map(\.name) == ["big", "root.bin", "small"])
        #expect(model.children.allSatisfy { $0.size > 0 })
        // The largest child is auto-selected so the treemap has a subject
        // without a second click. Its own children come out size descending:
        // nested (2 MB) ahead of the two 1 MB files.
        #expect(model.selectedEntry?.name == "big")
        #expect(model.selectedEntry?.children.map(\.name) == ["nested", "a.bin", "b.bin"])
        #expect(!model.canGoBack)
        #expect(!model.canGoForward)
    }

    /// Drilling into a folder that the scan already measured is instant: the
    /// page must not start a second measurement, and there is nothing to wait
    /// for.
    @Test func enteringDrillsDownInstantly() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()

        model.enter(model.children[0])
        #expect(!model.isScanning, "an already-measured folder needs no scan")
        #expect(model.breadcrumb.count == 2)
        #expect(model.breadcrumb.last?.name == "big")
        #expect(Set(model.children.map(\.name)) == ["a.bin", "b.bin", "nested"])
        // Entering selects the largest child — nested at 2 MB — so the
        // treemap has a folder as its subject.
        #expect(model.selectedEntry?.name == "nested")
        #expect(model.selectedEntry?.children.map(\.name) == ["c.bin"])
        #expect(model.canGoBack)
        #expect(!model.canGoForward)

        model.goBack()
        #expect(model.breadcrumb.count == 1)
        #expect(model.children.map(\.name) == ["big", "root.bin", "small"])
        #expect(model.canGoForward)
        #expect(!model.canGoBack)

        // Re-entering is just as instant: the tree is already there.
        model.goForward()
        #expect(model.breadcrumb.count == 2)
        #expect(model.breadcrumb.last?.name == "big")
        model.goBack()
        model.enter(model.children[0])
        #expect(!model.isScanning)
        #expect(model.children.count == 3)
    }

    /// A treemap tile is a child of the *selected* entry, so entering one
    /// must keep that level in the breadcrumb — the spine is walked from the
    /// tree, so it reads root › big › nested and back still returns to where
    /// the drill-down started (the history only holds the browsed path).
    @Test func enteringATreemapTileKeepsTheSelectedLevelInTheBreadcrumb() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()
        // The treemap's subject is the auto-selected largest child, "big";
        // its children are the tiles.
        #expect(model.selectedEntry?.name == "big")

        let tile = try #require(model.selectedEntry?.children.first { $0.name == "nested" })
        model.enter(tile)
        await model.waitUntilSettled()
        #expect(model.breadcrumb.count == 3)
        #expect(model.breadcrumb[1].name == "big")
        #expect(model.breadcrumb[2].name == "nested")
        #expect(model.breadcrumb[2].path == tile.path)
        #expect(model.children.map(\.name) == ["c.bin"])
        #expect(model.canGoBack)

        // Back returns to the browsed directory, where the tile's parent is
        // just a row again — the history never contained the extra level.
        model.goBack()
        await model.waitUntilSettled()
        #expect(model.breadcrumb.count == 1)
        #expect(model.children.map(\.name) == ["big", "root.bin", "small"])
        #expect(model.canGoForward)
    }

    @Test func breadcrumbJumpTruncatesHistory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()

        model.enter(model.children[0])
        await model.waitUntilSettled()
        let nested = try #require(model.children.first { $0.name == "nested" })
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

    @Test func selectingAFileShowsNoChildren() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()

        let file = try #require(model.children.first { $0.name == "root.bin" })
        model.select(file.id)
        #expect(model.selectedEntry?.name == "root.bin")
        #expect(model.selectedEntry?.children.isEmpty == true)
    }

    /// The toolbar's home shortcut: one click from the disk root to the home
    /// folder, skipping the intermediate levels — every level on the path is
    /// already measured, so the jump is instant.
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
        model.startScan()
        await model.waitUntilSettled()
        #expect(model.children.map(\.name) == ["big", "root.bin", "home", "small"])

        model.goToHome()
        #expect(model.breadcrumb.count == 2)
        #expect(model.breadcrumb.last?.name == "home")
        #expect(model.children.map(\.name) == ["notes.txt"])
        #expect(model.canGoBack)

        // Jumping while already home is a no-op, not a history entry.
        let history = model.breadcrumb
        model.goToHome()
        #expect(model.breadcrumb.map(\.path) == history.map(\.path))
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
        model.activate()
        model.startScan()
        await model.waitUntilSettled()
        model.goToHome()
        await model.waitUntilSettled()

        let documents = try #require(model.children.first { $0.name == "Documents" })
        #expect(documents.isSkipped, "Documents must be listed as skipped")
        #expect(documents.size == 0, "a skipped folder is never measured")
        // Desktop is skipped too; the plain files are measured normally.
        #expect(model.children.first { $0.name == "Desktop" }?.isSkipped == true)
        #expect(model.children.first { $0.name == "notes.txt" }?.isSkipped == false)

        // Double-clicking a skipped row does not navigate — it selects, so
        // the detail can explain and offer the explicit scan.
        model.enter(documents)
        #expect(model.breadcrumb.count == 2, "a skipped folder is not entered")
        #expect(model.selectedEntry?.name == "Documents")

        // The explicit scan measures it and promotes the row.
        model.scanFolder(documents)
        #expect(model.isScanning, "the explicit scan runs the scanning screen")
        await model.waitUntilSettled()
        #expect(model.selectedEntry?.children.map(\.name) == ["report.pdf"])
        let promoted = try #require(model.children.first { $0.name == "Documents" })
        #expect(promoted.isSkipped == false, "the row is promoted after scanning")
        #expect(promoted.size >= 64 * 1024)

        // With the folder approved, entering it navigates normally now.
        model.enter(promoted)
        #expect(model.breadcrumb.last?.name == "Documents")
        #expect(model.children.map(\.name) == ["report.pdf"])
    }

    /// Past the depth budget a folder's children are not retained. Entering
    /// it scans that subtree — the same scanning-screen-then-results flow the
    /// whole disk got — and the row loses its "not expanded" state.
    @Test func truncatedFolderIsScannedOnEnter() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path, maxDepth: 1)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()
        #expect(model.children.map(\.name) == ["big", "root.bin", "small"])

        let big = try #require(model.children.first { $0.name == "big" })
        #expect(big.isTruncated)
        #expect(big.children.isEmpty)
        #expect(big.size > 3_900_000, "the size is measured past the budget")

        model.enter(big)
        #expect(model.isScanning, "entering a truncated folder scans it")
        #expect(model.breadcrumb.last?.name == "big")
        await model.waitUntilSettled()
        #expect(Set(model.children.map(\.name)) == ["a.bin", "b.bin", "nested"])
        #expect(model.currentEntry?.isTruncated == false, "the row is expanded after the scan")
        // The grafted level is navigable straight away — but nested sits at
        // the new budget's edge, so entering it scans once more, exactly like
        // the level below it did.
        let nested = try #require(model.children.first { $0.name == "nested" })
        model.enter(nested)
        #expect(model.isScanning)
        await model.waitUntilSettled()
        #expect(model.children.map(\.name) == ["c.bin"])
    }

    /// Selecting a row must never start a scan on its own: a single click
    /// cannot commit the user to a minute-long traversal. The treemap offers
    /// the explicit action instead.
    @Test func selectingATruncatedFolderDoesNotStartAScan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path, maxDepth: 1)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()

        let big = try #require(model.children.first { $0.name == "big" })
        model.select(big.id)
        #expect(!model.isScanning)
        #expect(model.selectedEntry?.name == "big")
        #expect(model.selectedEntry?.children.isEmpty == true)

        model.scanFolder(big)
        await model.waitUntilSettled()
        #expect(model.selectedEntry?.children.map(\.name) == ["nested", "a.bin", "b.bin"])
        #expect(!model.isScanning)
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
        model.startScan()
        await model.waitUntilSettled()

        let big = model.children[0]
        model.enter(big)
        await model.waitUntilSettled()
        #expect(model.selectedEntry?.name == "nested")

        model.select(big.id)
        #expect(model.selectedEntry?.name == "nested", "a stale select must not replace the selection")
        #expect(model.selectedEntry?.children.map(\.name) == ["c.bin"])
    }

    @Test func stopClearsTheScanningFlag() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        model.startScan()
        #expect(model.isScanning)

        model.rescanOrStop()
        #expect(!model.isScanning, "stop must clear the flag or the page stays on the scanning screen")
        #expect(model.root == nil, "a stopped whole-disk scan presents nothing")
    }

    /// A stopped scan stays stopped: coming back to the page shows the start
    /// screen again, and only the user's button restarts the measurement.
    @Test func cancelledScanStaysStoppedUntilTheUserStartsIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        model.startScan()
        model.cancelScan()
        #expect(!model.isScanning)

        model.activate()
        #expect(!model.isScanning, "reactivation must not restart the scan")
        #expect(model.root == nil, "the start screen comes back")

        model.startScan()
        await model.waitUntilSettled()
        #expect(model.children.count == 3)
    }

    /// Neither leaving the page nor an explicit stop takes the tree down: the
    /// browsed folder stays entered, and coming back shows the same results
    /// with no rescan — activation only scans a folder whose children the
    /// tree does not hold, and this one is fully measured.
    @Test func cancelKeepsTheTreeAndReactivationDoesNotRescan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()

        model.enter(model.children[0])
        model.cancelScan()
        model.activate()
        #expect(!model.isScanning)
        #expect(model.breadcrumb.count == 2)
        #expect(model.children.count == 3)
    }

    @Test func rescanDropsTheTreeAndStartsOver() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()
        model.enter(model.children[0])
        await model.waitUntilSettled()

        model.rescanOrStop()
        #expect(model.isScanning)
        await model.waitUntilSettled()
        // Navigation is reset to the root along with the tree.
        #expect(model.breadcrumb.count == 1)
        #expect(model.children.map(\.name) == ["big", "root.bin", "small"])
        #expect(!model.canGoBack)
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
        model.startScan()
        await model.waitUntilSettled()

        let entry = try #require(model.children.first { $0.name == "locked" })
        model.enter(entry)
        #expect(model.currentEntry?.isUnreadable == true)
        #expect(model.children.isEmpty)
        #expect(!model.isScanning)
    }

    /// The first scan of a tree has no denominator — nothing has been measured
    /// yet — and must not invent one. The scan that lands records its
    /// directory count, and the next scan of the same tree divides by it, so
    /// the scanning screen can show a fraction instead of a sweep.
    @Test func aRescanDividesByTheDirectoryCountThePreviousScanEndedOn() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (history, domain) = Self.historySuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        let model = DiskAnalysisModel(rootPath: fixture.path, history: history)
        model.activate()
        model.startScan()
        #expect(model.scanEstimatedTotal == nil, "a tree never scanned has no total to divide by")
        #expect(model.scanFraction == nil, "without a total there is no fraction to show")
        await model.waitUntilSettled()

        model.startScan()
        // The fixture holds four directories: the root, big, big/nested, small.
        #expect(model.scanEstimatedTotal == 4, "the remembered count is the previous scan's total")
        #expect(model.scanFraction == 0, "a rescan starts at zero of the remembered total")
        await model.waitUntilSettled()
    }

    /// The elapsed readout must keep moving while a scan runs. Regression
    /// guard: starting the timer once cleared the start instant it was
    /// supposed to read, so every tick no-opped and the readout sat at 0:00
    /// for the whole scan.
    @Test func theElapsedReadoutAdvancesWhileTheScanRuns() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)

        model.startScan()
        #expect(model.scanElapsed == .zero, "the readout starts at zero")
        // Ticked synchronously, before any await: the scan's task has not been
        // given a chance to run, so the measurement is still in flight and
        // its start instant is still there to read.
        model.tickElapsed()
        #expect(model.scanElapsed > .zero, "the timer must read the start instant the scan recorded")

        await model.waitUntilSettled()
        // A tick after the scan has stopped changes nothing: the clock belongs
        // to the finished measurement.
        let settled = model.scanElapsed
        model.tickElapsed()
        #expect(model.scanElapsed == settled)
    }

    /// A first scan has nothing remembered to divide by, so the concurrent
    /// count pass supplies the denominator: the ring fills and the remaining
    /// estimate can appear without waiting for a rescan.
    @Test func aFirstScanGetsItsDenominatorFromTheConcurrentCount() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let (history, domain) = Self.historySuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        let model = DiskAnalysisModel(rootPath: fixture.path, history: history)
        model.activate()
        model.startScan()
        #expect(model.scanEstimatedTotal == nil, "the count has not landed yet")
        await model.waitUntilSettled()
        // The history domain is empty, so this can only have come from the
        // count pass that ran alongside the measurement.
        #expect(model.scanEstimatedTotal == 4, "the count pass supplies the denominator the history lacks")
        #expect(model.scanFraction != nil)
    }

    /// The remembered count is only valid for a scan that enters the same
    /// folders. Approving a TCC-protected home folder adds its whole subtree
    /// to the traversal, so the old count would finish early and strand the
    /// ring at 100% — the lookup misses and the screen sweeps instead.
    @Test func approvingAProtectedFolderDropsTheRememberedDenominator() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home")
        try write(size: 64 * 1024, at: home.appendingPathComponent("Documents/report.pdf"))
        let (history, domain) = Self.historySuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        let model = DiskAnalysisModel(rootPath: fixture.path, homePath: home.path, history: history)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()

        model.startScan()
        #expect(model.scanEstimatedTotal != nil, "the same tree and skip set keep the denominator")
        await model.waitUntilSettled()

        model.goToHome()
        let documents = try #require(model.children.first { $0.name == "Documents" })
        model.scanFolder(documents)
        await model.waitUntilSettled()

        model.startScan()
        #expect(model.scanEstimatedTotal == nil, "a changed skip set invalidates the remembered count")
        await model.waitUntilSettled()
        // With the folder approved the traversal is larger, and the concurrent
        // count pass measures the new tree rather than reusing the old number.
        #expect(model.scanEstimatedTotal == 6, "the count pass supplies a fresh denominator")
    }

    /// The remaining-time estimate is linear extrapolation of the measured
    /// rate, gated on both a directory sample and an elapsed floor: the first
    /// seconds of a traversal are unrepresentative, and a number that swings
    /// is worse than none.
    @Test func remainingEstimateExtrapolatesTheRateOnlyOnceItHasSettled() {
        #expect(DiskAnalysisModel.remainingEstimate(elapsed: .zero, scanned: 5_000, total: 10_000) == nil, "no rate yet")
        #expect(
            DiskAnalysisModel.remainingEstimate(elapsed: .seconds(10), scanned: 1_000, total: 10_000) == nil,
            "below the sample floor the rate is still noise"
        )
        #expect(
            DiskAnalysisModel.remainingEstimate(elapsed: .seconds(5), scanned: 50_000, total: 500_000) == nil,
            "below the elapsed floor the shallow levels' fast rate would promise seconds"
        )
        #expect(
            DiskAnalysisModel.remainingEstimate(elapsed: .seconds(100), scanned: 10_000, total: 10_000) == nil,
            "nothing is left once the total is reached"
        )
        // 2 000 directories in 20 s is 0.01 s each; 8 000 left → 80 s.
        let remaining = DiskAnalysisModel.remainingEstimate(elapsed: .seconds(20), scanned: 2_000, total: 10_000)
        #expect(remaining?.components.seconds == 80)
        // The same rate on a bigger tree scales linearly.
        let longer = DiskAnalysisModel.remainingEstimate(elapsed: .seconds(20), scanned: 2_000, total: 100_000)
        #expect(longer?.components.seconds == 980)
    }

    /// Re-opening the page while a measurement runs must attach to the running
    /// scan, not start another one.
    ///
    /// This is the regression that stopping the cancel-on-leave exposes:
    /// `activate()` calls `ensureCurrentScanned()`, which starts a scan for a
    /// browsed folder whose children are missing. Mid-scan that folder *is*
    /// unexpanded, so without the in-flight guard the page would cancel a
    /// live measurement and begin again from zero every time the user looked
    /// at another sidebar row and came back.
    @Test func activationDuringASubtreeScanDoesNotRestartIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path, maxDepth: 1)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()

        let big = try #require(model.children.first { $0.name == "big" })
        model.enter(big)
        #expect(model.isScanning, "entering a truncated folder scans it")
        let starts = model.scanStartCount

        model.activate()
        #expect(model.isScanning, "coming back must leave the scan running")
        #expect(model.scanStartCount == starts, "coming back must not restart the scan")

        await model.waitUntilSettled()
        #expect(Set(model.children.map(\.name)) == ["a.bin", "b.bin", "nested"])
    }

    /// Back and forward walk the browsing history the way the toolbar arrows
    /// do — the one navigation path the breadcrumb tests do not exercise.
    @Test func backAndForwardFollowTheBrowsingHistory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path)
        model.activate()
        model.startScan()
        await model.waitUntilSettled()

        let big = try #require(model.children.first { $0.name == "big" })
        model.enter(big)
        #expect(model.currentPath == big.path)
        #expect(model.canGoBack)
        #expect(!model.canGoForward)

        model.goBack()
        #expect(model.currentPath == fixture.path)
        #expect(!model.canGoBack)
        #expect(model.canGoForward)

        model.goForward()
        #expect(model.currentPath == big.path)
        #expect(model.canGoBack)
        #expect(!model.canGoForward, "forward must be consumed, not replayed")
    }

    /// The home shortcut only moves inside the analyzed tree. A home folder the
    /// scan never measured would leave the breadcrumb pointing at a path with
    /// no node behind it, so the jump is dropped instead.
    @Test func goToHomeIgnoresAHomeOutsideTheTree() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = DiskAnalysisModel(rootPath: fixture.path, homePath: "/definitely/elsewhere")
        model.activate()
        model.startScan()
        await model.waitUntilSettled()

        model.goToHome()
        #expect(model.currentPath == fixture.path, "a home outside the tree must not navigate")
        #expect(!model.canGoBack, "a dropped jump must not touch the history either")
    }

    /// A scan that starts no count of its own — because the history already
    /// remembers one — must still clear the handle the previous scan's count
    /// left behind. `waitUntilSettled` polls that handle, so a stale one spins
    /// the poll forever; the regression this guards used to hang the test
    /// rather than fail it.
    @Test func aScanThatStartsNoCountLeavesNoHandleBehind() async throws {
        // A wide tree with a shallow budget: the count pass walks every
        // directory while the measurement stops at the budget, so the count is
        // still in flight when the measurement lands. That is the window in
        // which a rescan used to inherit the previous count's handle.
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for group in 0..<10 {
            for leaf in 0..<30 {
                let dir = fixture
                    .appendingPathComponent("group\(group)", isDirectory: true)
                    .appendingPathComponent("leaf\(leaf)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try write(size: 64, at: dir.appendingPathComponent("file.bin"))
            }
        }
        let (history, domain) = Self.historySuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }

        let model = DiskAnalysisModel(rootPath: fixture.path, maxDepth: 1, history: history)
        model.startScan()
        // Wait for the measurement only: `waitUntilSettled` would also wait for
        // the count, which is the thing under test.
        while model.root == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }

        // The history now remembers this tree, so this scan starts no count of
        // its own — and the handle the cancelled one left must go with it.
        model.startScan()
        #expect(!model.hasPendingCount, "a scan that starts no count left the previous handle behind")

        let settled = await settlesWithin(.seconds(10)) { await model.waitUntilSettled() }
        #expect(settled, "waitUntilSettled never returned — a count handle was left behind")
    }

    /// The first scan of a tree the history already knows starts no count at
    /// all, so nothing may be left in flight for the poll to wait on.
    @Test func aRememberedTreeStartsNoCountAndLeavesNothingPending() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        // Canonical spelling, so the home folders the skip set names resolve to
        // themselves — the signature below has to be the one the model computes,
        // and it names both spellings when they differ (/var → /private/var).
        let root = URL(fileURLWithPath: FileSystem.canonical(fixture.path))
        let (history, domain) = Self.historySuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        // A remembered count for exactly this tree and skip set, written the
        // way a finished scan would have written it.
        let signature = "1\u{1F}" + [
            "\(root.path)/Documents",
            "\(root.path)/Desktop",
            "\(root.path)/Downloads",
        ].sorted().joined(separator: "\u{1F}")
        history.record(root: root.path, signature: signature, directories: 4)

        let model = DiskAnalysisModel(rootPath: root.path, homePath: root.path, maxDepth: 1, history: history)
        model.startScan()
        #expect(model.scanEstimatedTotal == 4, "the remembered count is the denominator")
        #expect(!model.hasPendingCount, "a remembered tree must not start a count")

        let settled = await settlesWithin(.seconds(10)) { await model.waitUntilSettled() }
        #expect(settled, "waitUntilSettled never returned with nothing in flight")
    }

    /// Reports whether `body` returned within `budget`, returning as soon as it
    /// does rather than waiting the budget out.
    ///
    /// A body that loses the race is left running rather than cancelled:
    /// cancelling the model's poll would turn a hang into a busy loop, and by
    /// then the failure has already been recorded by the caller.
    private func settlesWithin(
        _ budget: Duration,
        _ body: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let flag = SettledFlag()
        let running = Task {
            await body()
            await flag.mark()
        }
        let deadline = ContinuousClock.now + budget
        while !(await flag.settled) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        _ = await running.value
        return true
    }

    /// Whether the awaited body finished; an actor so the two tasks that touch
    /// it do not race.
    private actor SettledFlag {
        private(set) var settled = false

        func mark() {
            settled = true
        }
    }

    /// An isolated UserDefaults domain, so a remembered count never leaks
    /// between tests — or into the app's real history.
    private static func historySuite() -> (ScanProgressHistory, String) {
        let domain = "mackit-disk-history-\(UUID().uuidString)"
        return (ScanProgressHistory(defaults: UserDefaults(suiteName: domain)!), domain)
    }
}
