import Foundation
import Testing

@testable import Mackit

/// The ignore list: the paths and rules the user asked never to see again.
///
/// The list is filled from the item context menu, so every test feeds the
/// view model exactly what the menu would — a path or a rule id — and checks
/// the two places the list has to hold: the merge funnel every scanner
/// reports through, and the rule tables handed to the engine.
@MainActor
struct IgnoreListTests {
    /// A view model whose settings writes are discarded.
    ///
    /// Every mutation persists, and the default sink writes the real shared
    /// settings file the two processes share — a test that ignored a path
    /// without redirecting it would silently change what the developer's own
    /// Mackit scans for. `settingsSink` is the seam that exists for exactly
    /// this (see `SettingsPersistenceTests`).
    private func makeVM() -> AppViewModel {
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { _ in }
        return vm
    }

    private func item(
        _ path: String,
        ruleID: String = "test.rule",
        isCommand: Bool = false
    ) -> JunkItem {
        JunkItem(
            ruleID: ruleID,
            title: (path as NSString).lastPathComponent,
            detail: "Test",
            path: path,
            category: .system,
            risk: .safe,
            isCommand: isCommand
        )
    }

    /// An ignored path never enters the list, whatever scanner reports it.
    @Test func ignoredPathIsFilteredAtTheMergeFunnel() {
        let vm = makeVM()
        vm.addIgnoredPath("/Users/me/Library/Caches/foo")

        vm.mergeDiscovered([
            item("/Users/me/Library/Caches/foo"),
            item("/Users/me/Library/Caches/bar"),
        ])

        #expect(vm.items.map(\.path) == ["/Users/me/Library/Caches/bar"])
    }

    /// An ignored rule stops its whole family of entries while the other
    /// rules of the same category keep theirs.
    @Test func ignoredRuleIsFilteredAtTheMergeFunnel() {
        let vm = makeVM()
        vm.addIgnoredRule("browser.chrome-cache")

        vm.mergeDiscovered([
            item("/Users/me/Library/Caches/Google/Chrome/Default/Cache", ruleID: "browser.chrome-cache"),
            item("/Users/me/Library/Caches/Firefox", ruleID: "browser.firefox-cache"),
        ])

        #expect(vm.items.map(\.ruleID) == ["browser.firefox-cache"])
    }

    /// A command-line entry has no path, so only its rule can ignore it —
    /// and an empty ignored path is refused at the door rather than
    /// matching every command entry.
    @Test func commandEntriesAreIgnoredByRuleOnly() {
        let vm = makeVM()
        vm.addIgnoredPath("")

        let command = item("", ruleID: "cli.brew-cleanup", isCommand: true)

        #expect(vm.ignoredPaths.isEmpty, "an empty path is not a list entry")
        #expect(vm.isIgnored(command) == false)

        vm.addIgnoredRule("cli.brew-cleanup")

        #expect(vm.isIgnored(command) == true, "the rule is the only handle a command entry has")
    }

    /// The static and CLI rules stream their batches through
    /// `apply(.discovered)`, not through the merge funnel, so the ignore
    /// list has to hold there as well — otherwise every path a static
    /// rule owns comes back on the next scan, and a path ignored while a
    /// scan is in flight flickers back into the list mid-scan.
    @Test func ignoredPathIsFilteredAtTheRuleStreamFunnel() {
        let vm = makeVM()
        vm.addIgnoredPath("/Users/me/Library/Caches/foo")

        vm.apply(.discovered([
            item("/Users/me/Library/Caches/foo", ruleID: "xcode.deriveddata"),
            item("/Users/me/Library/Caches/bar", ruleID: "xcode.deriveddata"),
        ]))

        #expect(vm.items.map(\.path) == ["/Users/me/Library/Caches/bar"])
    }

    /// The rule half holds at the rule-stream funnel too.
    @Test func ignoredRuleIsFilteredAtTheRuleStreamFunnel() {
        let vm = makeVM()
        vm.addIgnoredRule("browser.chrome-cache")

        vm.apply(.discovered([
            item("/Users/me/Library/Caches/Google/Chrome/Default/Cache", ruleID: "browser.chrome-cache"),
            item("/Users/me/Library/Caches/Firefox", ruleID: "browser.firefox-cache"),
        ]))

        #expect(vm.items.map(\.ruleID) == ["browser.firefox-cache"])
    }

    /// The static and CLI rules are filtered before the engine builds its
    /// work units, so an ignored rule costs nothing to run.
    @Test func ignoredRulesDropOutOfTheRuleTables() {
        let vm = makeVM()
        let before = vm.activeScanRules.count

        vm.addIgnoredRule("xcode.deriveddata")

        #expect(vm.activeScanRules.count == before - 1, "the ignored rule left the table")
        #expect(!vm.activeScanRules.contains { $0.id == "xcode.deriveddata" })
        #expect(vm.activeCLIRules.contains { $0.id == "cli.go-clean-cache" }, "unrelated CLI rules stay")

        vm.addIgnoredRule("cli.go-clean-cache")

        #expect(!vm.activeCLIRules.contains { $0.id == "cli.go-clean-cache" })
    }

    /// Adding a path drops the entry already listed, so the change is
    /// visible without waiting for the next scan — and it persists.
    @Test func addingAPathDropsTheListedEntryAndPersists() {
        var saved: [String: Any] = [:]
        let vm = AppViewModel(statsPolling: false)
        vm.settingsSink = { saved = $0 }
        vm.mergeDiscovered([
            item("/Users/me/Library/Caches/foo"),
            item("/Users/me/Library/Caches/bar"),
        ])

        vm.addIgnoredPath("/Users/me/Library/Caches/foo")

        #expect(vm.items.map(\.path) == ["/Users/me/Library/Caches/bar"])
        #expect(vm.ignoredPaths == ["/Users/me/Library/Caches/foo"])
        #expect(saved["ignoredPaths"] as? [String] == ["/Users/me/Library/Caches/foo"])
    }

    /// Adding a rule id drops every listed entry of that rule.
    @Test func addingARuleDropsItsListedEntries() {
        let vm = makeVM()
        vm.mergeDiscovered([
            item("/Users/me/Library/Caches/Google/Chrome/Default/Cache", ruleID: "browser.chrome-cache"),
            item("/Users/me/Library/Caches/Firefox", ruleID: "browser.firefox-cache"),
        ])

        vm.addIgnoredRule("browser.chrome-cache")

        #expect(vm.items.map(\.ruleID) == ["browser.firefox-cache"])
    }

    /// Removing an entry stops ignoring it (the next scan lists it again),
    /// and clearing empties both halves at once.
    @Test func removingAndClearingStopIgnoring() {
        let vm = makeVM()
        vm.addIgnoredPath("/Users/me/Library/Caches/foo")
        vm.addIgnoredRule("browser.chrome-cache")

        vm.removeIgnoredPath("/Users/me/Library/Caches/foo")
        vm.removeIgnoredRule("browser.chrome-cache")

        #expect(vm.ignoredPaths.isEmpty && vm.ignoredRules.isEmpty)
        // Removing what is not there is a no-op, not a crash.
        vm.removeIgnoredPath("/Users/me/Library/Caches/foo")

        vm.addIgnoredPath("/Users/me/Library/Caches/foo")
        vm.addIgnoredRule("browser.chrome-cache")
        vm.clearIgnoreList()

        #expect(vm.ignoredPaths.isEmpty && vm.ignoredRules.isEmpty)
        // A second clear changes nothing and writes nothing.
        vm.clearIgnoreList()
        #expect(vm.ignoredPaths.isEmpty && vm.ignoredRules.isEmpty)
    }
}
