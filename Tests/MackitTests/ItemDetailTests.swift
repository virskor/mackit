import Foundation
import Testing

@testable import Mackit

/// The item detail sheet: the view-model contract it is built on.
///
/// The sheet itself is layout and is deliberately not covered here (layout is
/// not unit-testable, see AGENTS.md). What is covered is the state that opens
/// it — the detail resolves the live entry, and every path that drops an
/// entry closes the sheet with it — and the single-entry clean, which must
/// go through the same engine, and the same refusals, as a batch clean.
@MainActor
struct ItemDetailTests {
    private func tempDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-detail-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(
        _ path: String,
        size: Int64 = 0,
        ruleID: String = "test.rule"
    ) -> JunkItem {
        JunkItem(
            ruleID: ruleID,
            title: (path as NSString).lastPathComponent,
            detail: "Test",
            path: path,
            category: .system,
            risk: .safe,
            size: size
        )
    }

    /// A view model that removes for real (never through the Trash) and
    /// never persists: the settings sink would otherwise write the real
    /// shared settings file the two processes share.
    private func makeVM() -> AppViewModel {
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { _ in }
        vm.moveToTrash = false
        return vm
    }

    // MARK: - Sheet state

    @Test func openingTheDetailResolvesTheLiveEntry() {
        let vm = makeVM()
        let entry = item("/tmp/mackit-detail-derived")
        vm.apply(.discovered([entry]))

        vm.showItemDetail(entry)
        #expect(vm.detailItem?.id == entry.id)

        vm.dismissItemDetail()
        #expect(vm.detailItem == nil)
    }

    /// The sheet holds an id, not the entry: an entry that leaves the list
    /// closes the sheet instead of leaving it describing something gone.
    @Test func theDetailFollowsTheEntryOutOfTheList() {
        let vm = makeVM()
        let entry = item("/tmp/mackit-detail-derived")
        vm.apply(.discovered([entry, item("/tmp/mackit-detail-other")]))
        vm.showItemDetail(entry)

        vm.removeCleanedItems([entry.id])

        #expect(vm.detailItem == nil)
        // The id is cleared, not merely left unresolved: a rescan
        // rediscovers the same paths under the same ids, and a lingering id
        // would pop the sheet back open mid-scan.
        #expect(vm.detailItemID == nil)
    }

    /// Same property at the rescan boundary: a new scan drops the whole
    /// list, and the entry it rediscovers must not reopen the sheet.
    @Test func aRescanClosesTheDetail() {
        let vm = makeVM()
        let entry = item("/tmp/mackit-detail-derived")
        vm.apply(.discovered([entry]))
        vm.showItemDetail(entry)

        vm.resetForNewScan()
        #expect(vm.detailItemID == nil)

        vm.apply(.discovered([entry]))
        #expect(vm.detailItem == nil)
    }

    // MARK: - Single-entry clean

    @Test func cleanSingleRemovesTheEntryAndReportsSuccess() async throws {
        let base = tempDirectory("clean")
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("cache-bytes".utf8).write(to: target.appendingPathComponent("cache.bin"))

        let vm = makeVM()
        let entry = item(target.path, size: 11)
        vm.apply(.discovered([entry]))
        vm.showItemDetail(entry)

        let outcome = await vm.cleanSingle(entry)

        #expect(outcome.succeeded)
        #expect(vm.items.isEmpty)
        // The entry leaving the list is what closes the sheet — its binding
        // resolves the live entry.
        #expect(vm.detailItem == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(vm.banner?.style == .success)
    }

    /// A protected path is refused without touching disk, exactly as in a
    /// batch clean: the sheet's clean is the same engine, not a shortcut
    /// around the checks.
    @Test func cleanSingleRefusesAProtectedPathAndKeepsTheEntry() async {
        let vm = makeVM()
        let entry = item("/Library/Apple/mackit-should-never-exist-\(UUID().uuidString)")
        vm.apply(.discovered([entry]))
        vm.showItemDetail(entry)

        let outcome = await vm.cleanSingle(entry)

        #expect(!outcome.succeeded)
        #expect(vm.items.count == 1)
        // A failed clean leaves the sheet on the entry, with the engine's
        // message for it to show.
        #expect(vm.detailItem?.id == entry.id)
        #expect(!FileManager.default.fileExists(atPath: entry.path))
    }

    /// An entry that vanished since the scan is done as far as the list is
    /// concerned — nothing left to delete — so it leaves the list instead of
    /// padding the count, and no space is claimed.
    @Test func cleanSingleOfAnEntryThatVanishedStillClearsTheList() async {
        let vm = makeVM()
        let entry = item("/tmp/mackit-detail-never-existed-\(UUID().uuidString)", size: 4096)
        vm.apply(.discovered([entry]))

        let outcome = await vm.cleanSingle(entry)

        #expect(outcome.succeeded)
        #expect(outcome.reclaimed == 0)
        #expect(vm.items.isEmpty)
    }

    /// A command-line entry with nothing to run fails with the engine's own
    /// message rather than trapping or silently succeeding.
    @Test func cleanSingleOfAnEmptyCommandFails() async {
        let vm = makeVM()
        let entry = JunkItem(
            ruleID: "cli.test",
            title: "Test Command",
            detail: "Test",
            path: "",
            category: .xcode,
            risk: .review,
            isCommand: true,
            command: []
        )
        vm.apply(.discovered([entry]))

        let outcome = await vm.cleanSingle(entry)

        #expect(!outcome.succeeded)
        #expect(vm.items.count == 1)
    }
}
