import Foundation
import Testing

@testable import Mackit

/// The general cleanup page's row folds.
///
/// A grouped row's sub-rows fold away behind the header's disclosure: a
/// language list or an app list is long enough to bury every row below it.
/// Folding is presentation only — the selection, and with it what a checked
/// row sweeps, must not move.
@MainActor
struct GeneralRowFoldTests {
    /// One app-junk entry per name, so the app-junk row gets exactly
    /// `names.count` sub-rows.
    private func appJunkItems(_ names: [String]) -> [JunkItem] {
        names.map { name in
            JunkItem(
                ruleID: AppScanner.junkRuleID,
                title: name,
                detail: "Test",
                path: "/Users/me/Library/Caches/\(name)",
                category: .appJunk,
                risk: .safe,
                size: 1024,
                appName: name
            )
        }
    }

    private func row(_ id: String, in vm: AppViewModel) -> AppViewModel.GeneralRuleRowState? {
        vm.generalCleanGroups.flatMap(\.rows).first { $0.row.id == id }
    }

    /// Above the threshold a row folds; below it the list stays open.
    @Test func longGroupedRowFoldsAndShortOneStaysOpen() {
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { _ in }
        vm.mergeDiscovered(appJunkItems((1...8).map { "App\($0)" }))

        let long = row("app.junk", in: vm)
        #expect(long?.subRows.count == 8)
        #expect(long?.isExpanded == false, "a long list folds so it cannot bury the rows below it")
        // Folding is presentation only: a checked row still sweeps
        // everything it holds.
        #expect(long?.selectedCount == 8, "folding must not move the selection")

        // The short half needs its own model: merging one more entry
        // into the folded row above would keep it folded — the row's
        // fold state is the user's once it exists — so the "stays open"
        // claim is only meaningful against a list that was never long.
        let shortVM = AppViewModel(statsPolling: false)
        shortVM.settingsSink = { _ in }
        shortVM.mergeDiscovered(appJunkItems(["Solo"]))
        let short = row("app.junk", in: shortVM)
        #expect(short?.subRows.count == 1)
        #expect(short?.isExpanded == true, "a short list has nothing to hide and stays open")
    }

    /// The threshold itself: exactly at it a row stays open, one past it folds.
    @Test func theThresholdIsTheBoundary() {
        let at = AppViewModel(statsPolling: false)
        at.settingsSink = { _ in }
        at.mergeDiscovered(appJunkItems((1...AppViewModel.subRowCollapseThreshold).map { "App\($0)" }))
        #expect(row("app.junk", in: at)?.isExpanded == true, "a list at the threshold has nothing to hide")

        let past = AppViewModel(statsPolling: false)
        past.settingsSink = { _ in }
        past.mergeDiscovered(
            appJunkItems((1...(AppViewModel.subRowCollapseThreshold + 1)).map { "App\($0)" })
        )
        #expect(row("app.junk", in: past)?.isExpanded == false)
    }

    /// The user's own fold wins over the default, and a rebuild — which
    /// recomputes every row state — does not undo it.
    @Test func userFoldWinsAndSurvivesARebuild() {
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { _ in }
        vm.mergeDiscovered(appJunkItems((1...8).map { "App\($0)" }))

        vm.setGeneralRowExpanded("app.junk", expanded: true)
        #expect(row("app.junk", in: vm)?.isExpanded == true)

        // A rescan rebuilds the rows from scratch.
        vm.mergeDiscovered(appJunkItems(["App9"]))
        #expect(row("app.junk", in: vm)?.isExpanded == true, "a rebuild must not unfold what the user folded")

        vm.setGeneralRowExpanded("app.junk", expanded: false)
        #expect(row("app.junk", in: vm)?.isExpanded == false)
        // Setting the same value again is a no-op, not a cache drop.
        vm.setGeneralRowExpanded("app.junk", expanded: false)
        #expect(row("app.junk", in: vm)?.isExpanded == false)
    }

    /// A flat row has no sub-rows, so it never folds.
    @Test func flatRowsNeverFold() {
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { _ in }
        vm.mergeDiscovered([
            JunkItem(
                ruleID: "system.logs",
                title: "Foo",
                detail: "Test",
                path: "/Users/me/Library/Logs/Foo",
                category: .system,
                risk: .safe,
                size: 2048
            )
        ])

        let logs = row("system.logs", in: vm)
        #expect(logs?.subRows.isEmpty == true)
        #expect(logs?.isExpanded == false, "a flat row has no sub-rows to fold")
    }
}
