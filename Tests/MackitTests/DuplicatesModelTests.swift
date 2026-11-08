import Foundation
import Testing
import os

@testable import Mackit

/// File-scoped so the @Sendable fixture closures can use them without
/// crossing the test suite's MainActor isolation.
private let fixtureHome = "/Users/x"

/// A group of `count` copies of one file, dated so the keeper choice is
/// deterministic: copy `i` is `i` days older than copy `i-1`, and every path
/// is spelled to the same length so the tie-break never interferes.
private func fixtureGroup(
    id: String,
    count: Int,
    size: Int64 = 1_000_000,
    modified: Bool = true
) -> DuplicateGroup {
    let files = (0..<count).map { i -> DuplicateFile in
        let path = "\(fixtureHome)/set\(id)/copy\(i).bin"
        return DuplicateFile(
            path: path,
            name: "copy\(i).bin",
            size: size,
            modified: modified ? Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86_400) : nil,
            parentPath: "\(fixtureHome)/set\(id)",
            nodeIdentity: FileSystem.NodeIdentity(device: 1, node: UInt64(i + 1))
        )
    }
    return DuplicateGroup(id: id, files: files)
}

/// The duplicate-file tool's state model, driven through injected fixture
/// streams. These tests pin the page's contract: groups stream in with
/// nothing checked — every deletion check is the user's own act, and the
/// suggested keeper is marked by a badge only — the confirmation → clean
/// flow removes files and dissolves emptied groups, the clean engine's item
/// mapping keeps the vnode identity, and the threshold re-scans on top of a
/// finished scan.
@MainActor
struct DuplicatesModelTests {
    /// Counts the scans and cleans the fixture model ran.
    private final class Counters: @unchecked Sendable {
        var scans = 0
        var cleans = 0
    }

    /// Holds what the fake clean received, so the @Sendable fixture closure
    /// can hand it back without capturing a mutable local.
    private final class CleanRecorder: @unchecked Sendable {
        var items: [JunkItem] = []
        var moveToTrash = false
    }

    /// Opens the fixture scan's stream on demand, so a test can hold the
    /// scan in flight while it asserts on mid-scan behavior.
    private final class Gate: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        var isOpen: Bool { state.withLock { $0 } }
        func open() { state.withLock { $0 = true } }
    }

    /// Builds a model whose scan replays `streams[n]` for the n-th scan and
    /// whose clean reports one success per requested item.
    private func makeModel(
        streams: [@Sendable (AsyncStream<DuplicateFileScanEvent>.Continuation) -> Void],
        counters: Counters = Counters(),
        cleanRecorder: CleanRecorder? = nil
    ) -> DuplicatesModel {
        DuplicatesModel(
            rootPath: fixtureHome,
            scan: { _, _, _ in
                counters.scans += 1
                let n = counters.scans - 1
                // Each fixture stream owns its lifetime: it yields what it
                // has to say and finishes itself, so a fixture can hold the
                // stream open (the gate test) instead of ending the moment
                // it is built.
                return AsyncStream(DuplicateFileScanEvent.self) { continuation in
                    if n < streams.count {
                        streams[n](continuation)
                    } else {
                        continuation.finish()
                    }
                }
            },
            clean: { items, moveToTrash in
                counters.cleans += 1
                if let cleanRecorder {
                    cleanRecorder.items = items
                    cleanRecorder.moveToTrash = moveToTrash
                }
                return AsyncStream(CleanEvent.self) { continuation in
                    continuation.yield(.started(total: items.count))
                    for (index, item) in items.enumerated() {
                        continuation.yield(.progress(completed: index, total: items.count, current: item.title))
                        continuation.yield(.outcome(CleanOutcome(
                            id: "\(item.id)-outcome",
                            itemID: item.id,
                            title: item.title,
                            path: item.path,
                            reclaimed: item.size,
                            succeeded: true,
                            message: "",
                            movedToTrash: moveToTrash
                        )))
                    }
                    let reclaimed = items.reduce(Int64(0)) { $0 + $1.size }
                    continuation.yield(.finished(reclaimed: reclaimed, failures: 0))
                    continuation.finish()
                }
            }
        )
    }

    /// Polls until `condition` holds. The same 10 ms × 500 budget the other
    /// suites use.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func groupsStreamInUncheckedAndCountsAddUp() async {
        let model = makeModel(streams: [
            { continuation in
                continuation.yield(.progress(scanned: 5, current: "\(fixtureHome)/a"))
                continuation.yield(.found(fixtureGroup(id: "one", count: 3)))
                continuation.yield(.found(fixtureGroup(id: "two", count: 2)))
                continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 4))
            }
        ])

        model.startScan()
        await model.waitUntilSettled()

        #expect(model.groups.count == 2)
        #expect(model.totalFiles == 5)
        #expect(model.totalWasted == 3_000_000, "two redundant copies in the triplet, one in the pair")
        #expect(model.unreadableDirectories == 0)
        #expect(model.skippedLinkedFiles == 4)
        #expect(model.scanCompleted)
        #expect(model.hasScanned)
        #expect(!model.isScanning)

        // Nothing arrives checked: pre-ticking deletions would put files in
        // the Trash one careless click after the scan, so every check is
        // the user's own act. The suggestion lives in the "keep" badge.
        #expect(model.selectedPaths.isEmpty)
        for group in model.groups {
            for file in group.files {
                #expect(!model.isSelected(file))
            }
        }
        #expect(model.groupsFullySelected == 0)
    }

    @Test func theKeptCopyIsTheOldest() async {
        // copy0 is the oldest (dates increase with the index) — it must be
        // the badge's suggested keeper.
        let model = makeModel(streams: [
            { continuation in
                continuation.yield(.found(fixtureGroup(id: "one", count: 3)))
                continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
            continuation.finish()
            }
        ])

        model.startScan()
        await model.waitUntilSettled()

        let group = model.groups[0]
        #expect(DuplicatesModel.keptPath(in: group) == "\(fixtureHome)/setone/copy0.bin")
        #expect(model.isKept(group.files[0]))
        #expect(!model.isKept(group.files[1]))
    }

    @Test func undatedCopiesNeverCountAsTheOldest() async {
        // One dated copy among undated ones: the date decides, the path rule
        // only orders the undated. The undated paths are spelled to
        // different lengths so the tie-break is observable.
        let dated = DuplicateFile(
            path: "\(fixtureHome)/z/copy2.bin", name: "copy2.bin", size: 1_000_000,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            parentPath: "\(fixtureHome)/z", nodeIdentity: nil)
        let short = DuplicateFile(
            path: "\(fixtureHome)/a.bin", name: "a.bin", size: 1_000_000,
            modified: nil, parentPath: fixtureHome, nodeIdentity: nil)
        let long = DuplicateFile(
            path: "\(fixtureHome)/aaaaaa/copy9.bin", name: "copy9.bin", size: 1_000_000,
            modified: nil, parentPath: "\(fixtureHome)/aaaaaa", nodeIdentity: nil)
        let mixed = DuplicateGroup(id: "mixed", files: [long, short, dated])

        #expect(DuplicatesModel.keptPath(in: mixed) == dated.path)

        // With no date at all, the shortest path keeps the content.
        let undated = DuplicateGroup(id: "undated", files: [long, short])
        #expect(DuplicatesModel.keptPath(in: undated) == short.path)
    }

    @Test func selectionTogglesFollowTheUser() async {
        let model = makeModel(streams: [
            { continuation in
                continuation.yield(.found(fixtureGroup(id: "one", count: 2)))
                continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
            continuation.finish()
            }
        ])

        model.startScan()
        await model.waitUntilSettled()

        // Nothing arrives checked; a check exists only because the user
        // made it.
        let copy = model.groups[0].files[1]
        #expect(!model.isSelected(copy))
        #expect(model.selectedFiles.isEmpty)
        #expect(model.selectedSize == 0)
        #expect(model.groupsFullySelected == 0)

        model.setSelected(copy, selected: true)
        #expect(model.isSelected(copy))
        #expect(model.selectedSize == copy.size)
        #expect(model.groupsFullySelected == 0, "the keeper is unchecked, so the group survives")

        model.setSelected(copy, selected: false)
        #expect(model.selectedFiles.isEmpty)

        // Selecting the keeper too is the one way a group loses everything —
        // exactly what the confirmation sheet's warning is for.
        model.setSelected(copy, selected: true)
        model.setSelected(model.groups[0].files[0], selected: true)
        #expect(model.groupsFullySelected == 1, "both copies checked — the group loses everything")
    }

    @Test func searchFilterScopesTheTrashSelection() async {
        let model = makeModel(streams: [
            { continuation in
                continuation.yield(.found(fixtureGroup(id: "one", count: 3)))
                continuation.yield(.found(fixtureGroup(id: "two", count: 2)))
                continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
            continuation.finish()
            }
        ])

        model.startScan()
        await model.waitUntilSettled()

        // The user checks one copy in each group.
        model.setSelected(model.groups[0].files[1], selected: true)
        model.setSelected(model.groups[1].files[1], selected: true)
        #expect(model.selectedFiles.count == 2)

        // The filter narrows the list to the "one" group; the trash
        // selection follows the visible list, so the confirmation sheet can
        // never name a file the user cannot see.
        model.searchText = "setone"
        #expect(model.visibleGroups.count == 1)
        #expect(model.selectedFiles.count == 1)
        #expect(model.selectedFiles.allSatisfy { $0.parentPath.hasSuffix("setone") })

        // Clearing the filter restores the full selection — the checks were
        // never removed, only hidden.
        model.searchText = ""
        #expect(model.selectedFiles.count == 2)
        #expect(model.selectedSize == 2_000_000)
    }

    @Test func requestCleanWaitsForSelectionAndScan() async {
        let gate = Gate()
        let model = makeModel(streams: [
            { continuation in
                continuation.yield(.found(fixtureGroup(id: "one", count: 2)))
                // The stream stays open until the test opens the gate, so
                // the scan is verifiably still running. The gate is watched
                // off the build closure, which is synchronous.
                Task.detached {
                    while !gate.isOpen {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
                    continuation.finish()
                }
            }
        ])

        model.startScan()
        await waitUntil { model.groups.count == 1 }

        // The user checks a streamed row while the scan is still running;
        // the request is still refused, because the list is a moving target.
        #expect(model.isScanning)
        model.setSelected(model.groups[0].files[1], selected: true)
        #expect(!model.selectedFiles.isEmpty)
        model.requestClean()
        #expect(model.phase == .idle)

        gate.open()
        await model.waitUntilSettled()

        model.requestClean()
        #expect(model.phase == .confirming)
        model.cancelConfirmation()
        #expect(model.phase == .idle)
    }

    @Test func cleanRemovesFilesAndDissolvesEmptiedGroups() async {
        let recorder = CleanRecorder()
        let model = makeModel(
            streams: [
                { continuation in
                    continuation.yield(.found(fixtureGroup(id: "one", count: 3)))
                    continuation.yield(.found(fixtureGroup(id: "two", count: 2)))
                    continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
                continuation.finish()
                }
            ],
            cleanRecorder: recorder
        )

        model.startScan()
        await model.waitUntilSettled()

        // The user checks every copy but the suggested keeper of each group.
        for group in model.groups {
            let kept = DuplicatesModel.keptPath(in: group)
            for file in group.files where file.path != kept {
                model.setSelected(file, selected: true)
            }
        }
        model.requestClean()
        model.beginClean(moveToTrash: true)
        await model.waitUntilSettled()

        // One JunkItem per checked copy, carrying the clean rule id and the
        // vnode identity the engine re-checks.
        #expect(recorder.items.count == 3)
        #expect(recorder.moveToTrash)
        #expect(recorder.items.allSatisfy { $0.ruleID == "duplicateFile" })
        #expect(recorder.items.allSatisfy { $0.nodeIdentity != nil })
        #expect(recorder.items.allSatisfy { $0.isDirectory == false })

        #expect(model.phase == .done)
        #expect(model.cleanedCount == 3)
        #expect(model.reclaimed == 3_000_000)
        #expect(model.failures == 0)
        #expect(model.movedToTrash)
        // Both groups are left with a single file — no longer a duplicate —
        // so both dissolve.
        #expect(model.groups.isEmpty)
        #expect(model.selectedPaths.isEmpty)

        model.dismissResult()
        #expect(model.phase == .idle)
    }

    @Test func theKeepBadgeMovesWhenTheKeeperIsCleaned() async throws {
        let recorder = CleanRecorder()
        let model = makeModel(
            streams: [
                { continuation in
                    continuation.yield(.found(fixtureGroup(id: "one", count: 3)))
                    continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
                    continuation.finish()
                }
            ],
            cleanRecorder: recorder
        )

        model.startScan()
        await model.waitUntilSettled()

        // copy0 is the oldest — the suggested keeper. The user checks only
        // the keeper and cleans it: the group survives with two copies, and
        // the badge must move to the next-oldest survivor rather than stay
        // on the path that just left the disk.
        let keeper = model.groups[0].files[0]
        #expect(model.isKept(keeper))
        model.setSelected(keeper, selected: true)
        model.requestClean()
        model.beginClean(moveToTrash: true)
        await model.waitUntilSettled()

        #expect(model.groups.count == 1, "three copies cleaned down to two is still a group")
        let survivors = model.groups[0].files
        #expect(survivors.map(\.name).sorted() == ["copy1.bin", "copy2.bin"])
        #expect(
            survivors.filter { model.isKept($0) }.map(\.name) == ["copy1.bin"],
            "exactly the next-oldest survivor carries the badge"
        )
        #expect(model.isKept(keeper) == false, "the cleaned path carries no badge")
    }

    @Test func thresholdChangeRescansOnlyAfterAFinishedScan() async {
        let counters = Counters()
        let model = makeModel(
            streams: [
                { continuation in
                    continuation.yield(.found(fixtureGroup(id: "one", count: 2)))
                    continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
                continuation.finish()
                },
                { continuation in
                    continuation.yield(.found(fixtureGroup(id: "two", count: 2)))
                    continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
                continuation.finish()
                },
            ],
            counters: counters
        )

        // Before the first scan the new threshold is simply what the first
        // scan will use — no scan starts behind the user's back.
        model.setThreshold(.mb10)
        #expect(counters.scans == 0)

        model.startScan()
        await model.waitUntilSettled()
        #expect(counters.scans == 1)
        #expect(model.groups.map(\.id) == ["one"])

        // On top of a finished scan, a threshold change re-scans: the
        // threshold is applied during enumeration and cannot be recovered by
        // filtering the existing list.
        model.setThreshold(.mb100)
        await model.waitUntilSettled()
        #expect(counters.scans == 2)
        #expect(model.groups.map(\.id) == ["two"], "the new scan replaces the old groups")
    }

    @Test func searchFilterAlsoScopesTheAllCopiesWarning() async {
        let model = makeModel(streams: [
            { continuation in
                continuation.yield(.found(fixtureGroup(id: "one", count: 3)))
                continuation.yield(.found(fixtureGroup(id: "two", count: 2)))
                continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
                continuation.finish()
            }
        ])

        model.startScan()
        await model.waitUntilSettled()

        for file in model.groups[0].files {
            model.setSelected(file, selected: true)
        }
        #expect(model.groupsFullySelected == 1)

        // The filter hides the fully selected group. The sheet only deletes
        // the files it lists, so the warning must follow the visible list
        // too — otherwise it warns about content the confirm button will
        // leave untouched.
        model.searchText = "settwo"
        #expect(model.visibleGroups.count == 1)
        #expect(model.groupsFullySelected == 0)
        #expect(model.selectedFiles.isEmpty)

        model.searchText = ""
        #expect(model.groupsFullySelected == 1, "clearing the filter restores the warning")
    }

    @Test func sortOrdersGroupsByContentSizeInBothDirections() async {
        // The triplet holds smaller copies and the pair larger ones, chosen
        // so reclaimable bytes tie at 2 MB either way: the size sort must
        // follow the content size, not the reclaimable figure the last scan
        // happened to order by.
        let model = makeModel(streams: [
            { continuation in
                continuation.yield(.found(fixtureGroup(id: "small", count: 3, size: 1_000_000)))
                continuation.yield(.found(fixtureGroup(id: "large", count: 2, size: 2_000_000)))
                continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
                continuation.finish()
            }
        ])

        model.startScan()
        await model.waitUntilSettled()

        #expect(model.groups.map(\.id) == ["small", "large"], "groups keep emission order")
        #expect(model.sort == .sizeDescending)
        #expect(model.visibleGroups.map(\.id) == ["large", "small"])

        model.sort = .sizeAscending
        #expect(model.visibleGroups.map(\.id) == ["small", "large"])
        #expect(model.groups.map(\.id) == ["small", "large"], "sorting is presentation only")
    }

    @Test func rescanAfterACleanLeavesTheResultCard() async {
        let counters = Counters()
        let model = makeModel(
            streams: [
                { continuation in
                    continuation.yield(.found(fixtureGroup(id: "one", count: 2)))
                    continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
                    continuation.finish()
                },
                { continuation in
                    continuation.yield(.found(fixtureGroup(id: "two", count: 2)))
                    continuation.yield(.finished(unreadableDirectories: 0, skippedLinkedFiles: 0))
                    continuation.finish()
                },
            ],
            counters: counters
        )

        model.startScan()
        await model.waitUntilSettled()
        model.setSelected(model.groups[0].files[1], selected: true)
        model.requestClean()
        model.beginClean(moveToTrash: true)
        await model.waitUntilSettled()
        #expect(model.phase == .done)

        // A threshold change starts a fresh scan. The result card belongs to
        // the previous list and must not stay on screen over the new one.
        model.setThreshold(.mb10)
        await model.waitUntilSettled()

        #expect(counters.scans == 2)
        #expect(model.phase == .idle)
        #expect(model.groups.map(\.id) == ["two"])
    }

    @Test func activatingThePageStartsNothing() async {
        // activate() is the hook the view model calls on every page entry;
        // it must never start work of its own.
        let counters = Counters()
        let model = makeModel(streams: [], counters: counters)
        model.activate()
        #expect(counters.scans == 0)
        #expect(!model.isScanning)
    }
}
