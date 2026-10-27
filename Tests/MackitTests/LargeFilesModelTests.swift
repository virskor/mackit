import Foundation
import Testing

@testable import Mackit

/// Tests for the large-file analysis tool's state model.
///
/// The model is driven through its injected closures: a fixture event list
/// stands in for the walk, a recording clean for the engine, so nothing here
/// touches the real disk. What is pinned is the page's contract — the walk
/// never starts on its own, a threshold change re-walks (except mid-walk),
/// hits stream in discovery order and are presented sorted, a stopped walk's
/// results are flagged partial, and the clean flow maps the selection through
/// the shared engine and removes what actually left the disk.
@MainActor
struct LargeFilesModelTests {
    private func file(_ name: String, size: Int64, path: String? = nil, modified: Date? = nil) -> LargeFile {
        LargeFile(
            path: path ?? "/Users/x/\(name)",
            name: name,
            size: size,
            modified: modified,
            parentPath: "/Users/x"
        )
    }

    /// A walk stand-in: replays the given events and finishes. Records the
    /// arguments it was called with, so a test can prove the threshold and
    /// the protected-path set reach the walk.
    private final class WalkCall: @unchecked Sendable {
        var roots: [String] = []
        var thresholds: [Int64] = []
        var protectedSets: [Set<String>] = []
    }

    private func fakeScan(
        events: [LargeFileScanEvent],
        call: WalkCall? = nil
    ) -> @Sendable (String, Set<String>, Int64) -> AsyncStream<LargeFileScanEvent> {
        { root, protected, threshold in
            call?.roots.append(root)
            call?.protectedSets.append(protected)
            call?.thresholds.append(threshold)
            return AsyncStream(LargeFileScanEvent.self) { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    /// A walk stand-in that never finishes: the stream stays open, so the
    /// model stays in its scanning state for as long as the test wants.
    private func unfinishedScan() -> @Sendable (String, Set<String>, Int64) -> AsyncStream<LargeFileScanEvent> {
        { _, _, _ in
            AsyncStream(LargeFileScanEvent.self) { continuation in
                continuation.yield(.progress(scanned: 1, current: "/Users/x"))
            }
        }
    }

    /// Records what the clean closure was called with, so a test can prove
    /// the tool forwards the shared setting rather than assuming it.
    private final class CleanCall: @unchecked Sendable {
        var moveToTrash: Bool?
        var paths: [String] = []
    }

    private func fakeClean(
        failing: Set<String> = [],
        movedToTrash: Bool = false,
        call: CleanCall? = nil
    ) -> (@MainActor @Sendable ([JunkItem], Bool) -> AsyncStream<CleanEvent>) {
        { items, useTrash in
            call?.moveToTrash = useTrash
            call?.paths = items.map(\.path)
            return AsyncStream(CleanEvent.self) { continuation in
                continuation.yield(.started(total: items.count))
                var reclaimed: Int64 = 0
                var failures = 0
                for item in items {
                    let succeeded = !failing.contains(item.path)
                    if succeeded {
                        reclaimed += item.size
                    } else {
                        failures += 1
                    }
                    continuation.yield(.outcome(CleanOutcome(
                        id: item.id, itemID: item.id, title: item.title, path: item.path,
                        reclaimed: succeeded ? item.size : 0, succeeded: succeeded,
                        message: succeeded ? "done" : "refused",
                        movedToTrash: succeeded && movedToTrash
                    )))
                }
                continuation.yield(.finished(reclaimed: reclaimed, failures: failures))
                continuation.finish()
            }
        }
    }

    /// Waits until `condition` holds, recording a failure after a short
    /// budget rather than hanging the suite. For streams that park on
    /// purpose — a stopped walk's or a cancelled clean's — where
    /// `waitUntilSettled` would never return.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition not met within the budget")
    }

    /// Three hits in a fixed discovery order, with sizes that sort
    /// differently from the order they arrive in.
    private var sampleEvents: [LargeFileScanEvent] {
        [
            .progress(scanned: 3, current: "/Users/x"),
            .found(file("big.bin", size: 3_000_000_000)),
            .found(file("small.bin", size: 1_200_000_000)),
            .found(file("mid.bin", size: 2_000_000_000)),
            .finished(unreadableDirectories: 2),
        ]
    }

    private func makeModel(
        events: [LargeFileScanEvent]? = nil,
        scan: (@Sendable (String, Set<String>, Int64) -> AsyncStream<LargeFileScanEvent>)? = nil,
        clean: (@MainActor @Sendable ([JunkItem], Bool) -> AsyncStream<CleanEvent>)? = nil
    ) -> LargeFilesModel {
        LargeFilesModel(
            rootPath: "/Users/x",
            scan: scan ?? fakeScan(events: events ?? sampleEvents),
            clean: clean ?? fakeClean()
        )
    }

    // MARK: - Lifecycle

    @Test func enteringThePageDoesNotStartAWalk() async {
        let call = WalkCall()
        let model = makeModel(scan: fakeScan(events: sampleEvents, call: call))

        model.activate()

        #expect(model.scanStartCount == 0, "a whole-disk walk is minutes of IO the user did not ask for")
        #expect(!model.isScanning)
        #expect(!model.hasScanned)
        #expect(model.files.isEmpty)
        #expect(call.roots.isEmpty)
    }

    @Test func startScanCollectsHitsInDiscoveryOrderAndPresentsThemSorted() async {
        let model = makeModel()

        model.startScan()
        await model.waitUntilSettled()

        #expect(model.hasScanned)
        #expect(model.scanCompleted)
        #expect(!model.isScanning)
        #expect(model.unreadableDirectories == 2, "the finished event's count reaches the page")
        // Stored in discovery order — the walk appends as it finds — while
        // the presented order is the sort's business.
        #expect(model.files.map(\.name) == ["big.bin", "small.bin", "mid.bin"])
        #expect(model.visibleFiles.map(\.name) == ["big.bin", "mid.bin", "small.bin"])
        #expect(model.totalSize == 3_000_000_000 + 2_000_000_000 + 1_200_000_000)
    }

    @Test func thresholdChangeBeforeTheFirstWalkIsJustRemembered() async {
        let call = WalkCall()
        let model = makeModel(scan: fakeScan(events: sampleEvents, call: call))

        model.setThreshold(.gb5)

        #expect(model.threshold == .gb5)
        #expect(model.scanStartCount == 0, "nothing to redo before the first walk")
    }

    @Test func thresholdChangeAfterAFinishedWalkStartsANewOne() async {
        let call = WalkCall()
        let model = makeModel(scan: fakeScan(events: sampleEvents, call: call))

        model.startScan()
        await model.waitUntilSettled()
        model.setThreshold(.mb500)

        #expect(model.scanStartCount == 2, "the threshold is baked into a walk, so a change re-walks")
        await model.waitUntilSettled()
        // The walk's arguments are recorded when its task runs, so the
        // thresholds are only both there once the second walk has settled.
        #expect(call.thresholds == [Int64(LargeFilesModel.Threshold.gb1.rawValue), 500_000_000])
        #expect(model.hasScanned)
    }

    @Test func thresholdChangeMidWalkIsRecordedButDoesNotRestart() async {
        let model = makeModel(scan: unfinishedScan())

        model.startScan()
        #expect(model.isScanning)

        model.setThreshold(.gb5)

        #expect(model.threshold == .gb5, "the picker's new value is kept")
        #expect(model.scanStartCount == 1, "restarting a minutes-long walk over a control the page disables would be its own bug")

        model.cancelScan()
        #expect(!model.isScanning)
    }

    @Test func stoppingAWalkKeepsItsHitsAndFlagsThemPartial() async {
        let hit = file("parked.bin", size: 4_000_000_000)
        // The stand-in yields one hit and then parks: the walk is still
        // running, so nothing marks the list complete.
        let model = LargeFilesModel(scan: { _, _, _ in
            AsyncStream(LargeFileScanEvent.self) { continuation in
                continuation.yield(.found(hit))
            }
        })

        model.startScan()
        await waitUntil { !model.files.isEmpty }
        model.cancelScan()

        #expect(!model.isScanning)
        #expect(!model.scanCompleted, "a stopped walk's list is not the complete answer")
        #expect(model.files.map(\.name) == ["parked.bin"], "whatever the walk already found is kept")
        #expect(!model.hasScanned, "a stopped walk never landed, so a threshold change will not auto redo it")
    }

    // MARK: - Search & sort

    @Test func searchFiltersByNameAndPath() async {
        let model = makeModel()
        model.startScan()
        await model.waitUntilSettled()

        model.searchText = "mid"
        #expect(model.visibleFiles.map(\.name) == ["mid.bin"])

        model.searchText = "SMALL"
        #expect(model.visibleFiles.map(\.name) == ["small.bin"], "the filter is case-insensitive")

        model.searchText = "/users"
        #expect(model.visibleFiles.count == 3, "the path is searchable too")

        model.searchText = "   "
        #expect(model.visibleFiles.count == 3, "whitespace is not a filter")
    }

    @Test func sortReordersWithoutTouchingTheWalk() async {
        let model = makeModel()
        model.startScan()
        await model.waitUntilSettled()

        model.sort = .name
        #expect(model.visibleFiles.map(\.name) == ["big.bin", "mid.bin", "small.bin"])

        model.sort = .nameDescending
        #expect(model.visibleFiles.map(\.name) == ["small.bin", "mid.bin", "big.bin"])

        model.sort = .sizeAscending
        #expect(model.visibleFiles.map(\.name) == ["small.bin", "mid.bin", "big.bin"])

        let older = Date(timeIntervalSince1970: 1_000_000_000)
        let newer = Date(timeIntervalSince1970: 1_900_000_000)
        let dated = LargeFilesModel(scan: fakeScan(events: [
            .found(LargeFile(path: "/u/old.bin", name: "old.bin", size: 1, modified: older, parentPath: "/u")),
            .found(LargeFile(path: "/u/new.bin", name: "new.bin", size: 1, modified: newer, parentPath: "/u")),
            .found(LargeFile(path: "/u/none.bin", name: "none.bin", size: 1, modified: nil, parentPath: "/u")),
            .finished(unreadableDirectories: 0),
        ]))
        dated.startScan()
        await dated.waitUntilSettled()

        dated.sort = .recentModified
        // Newest first, and a missing date last rather than masquerading as
        // "oldest".
        #expect(dated.visibleFiles.map(\.name) == ["new.bin", "old.bin", "none.bin"])

        dated.sort = .earliestModified
        // Oldest first — and the missing date still last: "unknown" is not
        // "oldest" in either direction.
        #expect(dated.visibleFiles.map(\.name) == ["old.bin", "new.bin", "none.bin"])
    }

    // MARK: - Selection & clean

    @Test func cleanMapsTheSelectionThroughTheEngineAndRemovesWhatLeft() async {
        let cleanCall = CleanCall()
        let model = makeModel(clean: fakeClean(movedToTrash: true, call: cleanCall))
        model.startScan()
        await model.waitUntilSettled()

        model.setSelected(model.files[0], selected: true)
        model.setSelected(model.files[2], selected: true)
        #expect(model.selectedFiles.count == 2)
        #expect(model.selectedSize == 3_000_000_000 + 2_000_000_000)

        model.requestClean()
        #expect(model.phase == .confirming)

        model.beginClean(moveToTrash: true)
        #expect(model.phase == .cleaning)
        await model.waitUntilSettled()

        #expect(model.phase == .done)
        #expect(cleanCall.moveToTrash == true, "the shared setting is forwarded per call")
        #expect(cleanCall.paths == ["/Users/x/big.bin", "/Users/x/mid.bin"], "the selection, in list order")
        #expect(model.cleanedCount == 2)
        #expect(model.reclaimed == 3_000_000_000 + 2_000_000_000)
        #expect(model.movedToTrash)
        #expect(model.files.map(\.name) == ["small.bin"], "deleted files leave the list in one batch")
        #expect(model.selectedPaths.isEmpty, "their checks go with them")

        model.dismissResult()
        #expect(model.phase == .idle)
    }

    @Test func aFailedCleanKeepsItsFileCheckedForARetry() async {
        let model = makeModel(clean: fakeClean(failing: ["/Users/x/big.bin"]))
        model.startScan()
        await model.waitUntilSettled()

        model.setSelected(model.files[0], selected: true)
        model.requestClean()
        model.beginClean(moveToTrash: false)
        await model.waitUntilSettled()

        #expect(model.failures == 1)
        #expect(model.files.map(\.name) == ["big.bin", "small.bin", "mid.bin"], "the file is still on disk, so it is still listed")
        #expect(model.selectedPaths == ["/Users/x/big.bin"], "and still checked, so it can be retried")
    }

    @Test func cancellingMidCleanKeepsWhatWasAlreadyRemoved() async {
        let big = file("big.bin", size: 3_000_000_000)
        // The clean stand-in reports the item as removed and then parks
        // before its finished event: the clean is still running.
        let model = LargeFilesModel(
            rootPath: "/Users/x",
            scan: fakeScan(events: [.found(big), .finished(unreadableDirectories: 0)]),
            clean: { items, useTrash in
                AsyncStream(CleanEvent.self) { continuation in
                    continuation.yield(.started(total: items.count))
                    for item in items {
                        continuation.yield(.outcome(CleanOutcome(
                            id: item.id, itemID: item.id, title: item.title, path: item.path,
                            reclaimed: item.size, succeeded: true,
                            message: "done", movedToTrash: useTrash
                        )))
                    }
                }
            }
        )
        model.startScan()
        await model.waitUntilSettled()

        model.setSelected(big, selected: true)
        model.requestClean()
        model.beginClean(moveToTrash: true)
        await waitUntil { model.cleanedCount == 1 }

        model.cancelClean()

        #expect(model.phase == .idle)
        #expect(model.files.isEmpty, "the file that already left the disk stays gone")
        #expect(model.selectedPaths.isEmpty, "and its check goes with it")
    }

    @Test func aCleanCannotStartWhileAWalkRuns() async {
        let hit = file("parked.bin", size: 4_000_000_000)
        // The stand-in yields one hit and parks: the walk is still running.
        let model = LargeFilesModel(scan: { _, _, _ in
            AsyncStream(LargeFileScanEvent.self) { continuation in
                continuation.yield(.found(hit))
            }
        })
        model.startScan()
        await waitUntil { !model.files.isEmpty }
        model.setSelected(model.files[0], selected: true)

        model.requestClean()

        #expect(model.phase == .idle, "the list is still streaming — deleting from a moving selection is how the wrong file goes")
        #expect(model.selectedPaths == [hit.path], "and the selection survives the refused request")
        model.cancelScan()
    }

    @Test func aThresholdChangeCannotStartAWalkUnderARunningClean() async {
        let big = file("big.bin", size: 3_000_000_000)
        // The clean stand-in reports the item and parks before its finished
        // event: the clean is still running when the threshold is touched.
        let model = LargeFilesModel(
            rootPath: "/Users/x",
            scan: fakeScan(events: [.found(big), .finished(unreadableDirectories: 0)]),
            clean: { items, useTrash in
                AsyncStream(CleanEvent.self) { continuation in
                    continuation.yield(.started(total: items.count))
                    for item in items {
                        continuation.yield(.outcome(CleanOutcome(
                            id: item.id, itemID: item.id, title: item.title, path: item.path,
                            reclaimed: item.size, succeeded: true,
                            message: "done", movedToTrash: useTrash
                        )))
                    }
                }
            }
        )
        model.startScan()
        await model.waitUntilSettled()
        model.setSelected(big, selected: true)
        model.requestClean()
        model.beginClean(moveToTrash: true)
        await waitUntil { model.cleanedCount == 1 }
        #expect(model.phase == .cleaning)

        model.setThreshold(.gb5)

        #expect(model.threshold == .gb1, "the change is refused whole — a walk must not start under a running clean")
        #expect(model.scanStartCount == 1)
        model.cancelClean()
    }

    @Test func startingAWalkDismissesAnOpenConfirmation() async {
        let model = makeModel()
        model.startScan()
        await model.waitUntilSettled()
        model.setSelected(model.files[0], selected: true)
        model.requestClean()
        #expect(model.phase == .confirming)

        // A rescan while the sheet is up would rebuild the list under it.
        model.startScan()

        #expect(model.phase == .idle, "the sheet is dismissed, not left promising a list that is being re-collected")
        await model.waitUntilSettled()
    }

    // MARK: - Protected paths

    @Test func aRescanDropsSelectionsForFilesThatAreGone() async {
        final class Counter: @unchecked Sendable { var walks = 0 }
        let counter = Counter()
        // The first walk finds two files; the second — a rescan after one was
        // deleted elsewhere — finds only the first.
        let model = LargeFilesModel(scan: { _, _, _ in
            counter.walks += 1
            let events: [LargeFileScanEvent] = counter.walks == 1
                ? [
                    .found(LargeFile(path: "/u/a.bin", name: "a.bin", size: 3_000_000_000, modified: nil, parentPath: "/u")),
                    .found(LargeFile(path: "/u/b.bin", name: "b.bin", size: 2_000_000_000, modified: nil, parentPath: "/u")),
                    .finished(unreadableDirectories: 0),
                ]
                : [
                    .found(LargeFile(path: "/u/a.bin", name: "a.bin", size: 3_000_000_000, modified: nil, parentPath: "/u")),
                    .finished(unreadableDirectories: 0),
                ]
            return AsyncStream(LargeFileScanEvent.self) { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        })
        model.startScan()
        await model.waitUntilSettled()

        model.setSelected(model.files[0], selected: true)
        model.setSelected(model.files[1], selected: true)
        #expect(model.selectedPaths.count == 2)

        model.startScan()
        await model.waitUntilSettled()

        #expect(model.files.map(\.name) == ["a.bin"])
        #expect(model.selectedPaths == ["/u/a.bin"], "the vanished file's check goes with it, the survivor's stays")
    }

    @Test func theProtectedSetReachesTheWalkAndTheOptInRewalks() async {
        let call = WalkCall()
        let model = makeModel(scan: fakeScan(events: sampleEvents, call: call))

        model.startScan()
        await model.waitUntilSettled()

        let protected = call.protectedSets[0]
        // The TCC-protected home trio, both spellings, minus nothing.
        #expect(protected.contains(FileSystem.expand("~/Documents")))
        #expect(protected.count >= 3, "Documents, Desktop and Downloads are all in the skip set")

        model.setIncludeProtectedPaths(true)
        #expect(model.scanStartCount == 2, "the protected set is baked into a walk, so the opt-in re-walks")
        await model.waitUntilSettled()
        #expect(call.protectedSets[1].isEmpty, "and the new walk enters the trio")
    }
}
