import Foundation
import Testing

@testable import Mackit

/// The startup-items scanner's pure logic: plist parsing, the
/// `print-disabled` dump, app matching, grouping, sorting and search.
///
/// The plist fixtures are written to a temporary directory (the same
/// pattern the leftover-cache tests use); nothing here touches the real
/// ~/Library or /Library.
struct LoginItemScannerTests {
    /// Writes one launchd plist fixture and returns its path.
    private func writePlist(
        _ label: String?,
        programArguments: [String]? = nil,
        program: String? = nil,
        in directory: URL,
        name: String = UUID().uuidString
    ) throws -> String {
        var dict: [String: Any] = [:]
        if let label { dict["Label"] = label }
        if let programArguments { dict["ProgramArguments"] = programArguments }
        if let program { dict["Program"] = program }
        dict["RunAtLoad"] = true
        let url = directory.appendingPathComponent("\(name).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
        return url.path
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-loginitems-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Plist parsing

    @Test func parsesLabelAndProgram() throws {
        let directory = try makeDirectory("plist-ok")
        let path = try writePlist(
            "com.example.agent",
            programArguments: ["/Applications/Example.app/Contents/MacOS/Example"],
            in: directory
        )
        let info = try #require(LoginItemScanner.parsePlist(at: path))
        #expect(info.label == "com.example.agent")
        #expect(info.programPath == "/Applications/Example.app/Contents/MacOS/Example")
    }

    @Test func fallsBackToTheProgramKey() throws {
        let directory = try makeDirectory("plist-program")
        let path = try writePlist("com.example.agent", program: "/usr/local/bin/example", in: directory)
        let info = try #require(LoginItemScanner.parsePlist(at: path))
        #expect(info.programPath == "/usr/local/bin/example")
    }

    @Test func skipsPlistsWithoutALabel() throws {
        let directory = try makeDirectory("plist-nolabel")
        // launchd itself refuses a plist without a Label; the scanner
        // skips it for the same reason.
        let path = try writePlist(nil, programArguments: ["/bin/sleep"], in: directory)
        #expect(LoginItemScanner.parsePlist(at: path) == nil)
    }

    @Test func skipsMalformedPlists() throws {
        let directory = try makeDirectory("plist-bad")
        // A hand-mangled file (an array where a dictionary belongs) and a
        // missing file are both skipped, never trusted.
        let url = directory.appendingPathComponent("array.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["not", "a", "dict"], format: .xml, options: 0)
        try data.write(to: url)
        #expect(LoginItemScanner.parsePlist(at: url.path) == nil)
        #expect(LoginItemScanner.parsePlist(at: directory.appendingPathComponent("gone.plist").path) == nil)
    }

    // MARK: Disabled-state parsing

    @Test func parsesTheDisabledDump() {
        // The real shape of `launchctl print-disabled` output, captured
        // from a live dump.
        let output = """
        	disabled services = {
        		"com.docker.socket" => enabled
        		"com.apple.ManagedClientAgent.enrollagent" => disabled
        		"com.example.service" => enabled
        	}
        """
        let states = LoginItemScanner.parseDisabledStates(output)
        #expect(states["com.docker.socket"] == true)
        #expect(states["com.apple.ManagedClientAgent.enrollagent"] == false)
        #expect(states["com.example.service"] == true)
        // The header and the closing brace are not entries.
        #expect(states.count == 3)
    }

    @Test func labelsWithoutAnOverrideReadAsEnabled() {
        // An absent label is the default state, applied by the caller;
        // the parse itself simply does not mention it.
        let states = LoginItemScanner.parseDisabledStates("\"com.example\" => disabled")
        #expect(states["com.other"] == nil)
    }

    @Test func aLabelContainingDisabledDoesNotFlipItsOwnState() {
        // Substring matching would read this label's own name as its
        // state; the value is compared as a whole token.
        let states = LoginItemScanner.parseDisabledStates("\"com.example.disabledhelper\" => enabled")
        #expect(states["com.example.disabledhelper"] == true)
    }

    @Test func aMissingDumpYieldsNoStates() {
        #expect(LoginItemScanner.parseDisabledStates(nil).isEmpty)
        #expect(LoginItemScanner.parseDisabledStates("").isEmpty)
    }

    // MARK: App matching

    private func app(_ bundleID: String, _ name: String, path: String) -> InstalledApp {
        InstalledApp(name: name, bundleID: bundleID, version: "1.0", path: path)
    }

    @Test func matchesTheAppTheProgramRunsFrom() {
        let apps = [app("com.example.foo", "Foo", path: "/Applications/Foo.app")]
        let matched = LoginItemScanner.matchApp(
            label: "com.unrelated.label",
            programPath: "/Applications/Foo.app/Contents/MacOS/foo",
            apps: apps
        )
        #expect(matched == MatchedApp(name: "Foo", path: "/Applications/Foo.app"))
    }

    @Test func matchesTheAppWhoseBundleIDTheLabelCarries() {
        let apps = [
            app("com.example.foo", "Foo", path: "/Applications/Foo.app"),
            app("com.example.bar", "Bar", path: "/Applications/Bar.app")
        ]
        let matched = LoginItemScanner.matchApp(
            label: "com.example.bar.helper",
            programPath: nil,
            apps: apps
        )
        #expect(matched == MatchedApp(name: "Bar", path: "/Applications/Bar.app"))
    }

    @Test func noMatchLeavesTheItemUngrouped() {
        let apps = [app("com.example.foo", "Foo", path: "/Applications/Foo.app")]
        #expect(LoginItemScanner.matchApp(label: "com.other.service", programPath: nil, apps: apps) == nil)
        // An empty bundle ID must not match everything.
        let ghost = [app("", "Ghost", path: "/Applications/Ghost.app")]
        #expect(LoginItemScanner.matchApp(label: "com.other.service", programPath: nil, apps: ghost) == nil)
    }

    @Test func aFileNamedLikeABundleIsNotABundle() {
        // "x.appliance" is not inside an .app bundle: the remainder after
        // ".app" must be a separator or nothing.
        let matched = LoginItemScanner.matchApp(
            label: "com.example.appliance",
            programPath: "/usr/local/bin/x.appliance",
            apps: []
        )
        #expect(matched == nil)
    }

    // MARK: Grouping and sorting

    private func item(
        _ id: String,
        label: String,
        enabled: Bool,
        kind: LoginItem.Kind = .userAgent,
        app: MatchedApp? = nil
    ) -> LoginItem {
        LoginItem(
            id: id,
            kind: kind,
            label: label,
            plistPath: "/Users/x/Library/LaunchAgents/\(label).plist",
            targetPath: nil,
            app: app,
            isEnabled: enabled
        )
    }

    @Test func groupsByAppWithUnmatchedItemsAlone() throws {
        let foo = MatchedApp(name: "Foo", path: "/Applications/Foo.app")
        let items = [
            item("a", label: "com.foo.agent", enabled: true, app: foo),
            item("b", label: "com.foo.helper", enabled: false, app: foo),
            item("c", label: "com.orphan.service", enabled: true)
        ]
        let groups = LoginItemScanner.group(items, sort: .name)
        #expect(groups.count == 2)

        let fooGroup = try #require(groups.first { $0.app?.path == "/Applications/Foo.app" })
        #expect(fooGroup.name == "Foo")
        #expect(fooGroup.items.count == 2)
        #expect(fooGroup.status == .partial)
        #expect(fooGroup.enabledCount == 1)

        let orphan = try #require(groups.first { $0.app == nil })
        #expect(orphan.name == "com.orphan.service")
        #expect(orphan.status == .allEnabled)
    }

    @Test func sortByNameIsLocalized() {
        let items = [
            item("b", label: "zebra", enabled: true),
            item("a", label: "apple", enabled: true)
        ]
        let groups = LoginItemScanner.group(items, sort: .name)
        #expect(groups.map(\.name) == ["apple", "zebra"])
    }

    @Test func sortByStatusPutsEnabledFirst() {
        let items = [
            item("a", label: "off.one", enabled: false),
            item("b", label: "on.one", enabled: true),
            item("c", label: "off.two", enabled: false)
        ]
        let groups = LoginItemScanner.group(items, sort: .status)
        // Enabled first, then the disabled ones in name order.
        #expect(groups.map(\.name) == ["on.one", "off.one", "off.two"])
    }

    // MARK: Search

    @Test func searchMatchesNameLabelAndPath() {
        let foo = MatchedApp(name: "Foo", path: "/Applications/Foo.app")
        let items = [
            item("a", label: "com.foo.agent", enabled: true, app: foo),
            item("b", label: "com.bar.service", enabled: true)
        ]
        let groups = LoginItemScanner.group(items, sort: .name)

        // By app name through the group, by label, and by plist path.
        #expect(LoginItemScanner.filter(groups, search: "foo").count == 1)
        #expect(LoginItemScanner.filter(groups, search: "bar").count == 1)
        #expect(LoginItemScanner.filter(groups, search: "com.foo.agent").count == 1)
        #expect(LoginItemScanner.filter(groups, search: "LaunchAgents").count == 2)
        // Whitespace-only and empty searches keep everything.
        #expect(LoginItemScanner.filter(groups, search: "   ").count == 2)
        #expect(LoginItemScanner.filter(groups, search: "").count == 2)
        // No match.
        #expect(LoginItemScanner.filter(groups, search: "nothing").isEmpty)
    }

    // MARK: Own-item filter

    @Test func mackitsOwnItemsAreFiltered() {
        #expect(LoginItemScanner.isOwnItem("cn.mingcui.mackit.agent"))
        #expect(LoginItemScanner.isOwnItem("cn.mingcui.mackit.helper"))
        #expect(LoginItemScanner.isOwnItem("cn.mingcui.mackit"))
        // A name that merely shares the leading characters is not the
        // same app.
        #expect(!LoginItemScanner.isOwnItem("cn.mingcui.mackitfoo"))
        #expect(!LoginItemScanner.isOwnItem("com.example.app"))
    }

    // MARK: The full scan

    @Test func theScanReadsEverySourceAndAppliesTheOverrides() async throws {
        let userDir = try makeDirectory("scan-user")
        let daemonDir = try makeDirectory("scan-daemon")

        // A user agent for a known app, a system daemon, a non-plist
        // file, a plist without a label, and Mackit's own daemon.
        _ = try writePlist(
            "com.example.foo",
            programArguments: ["/Applications/Foo.app/Contents/MacOS/foo"],
            in: userDir,
            name: "com.example.foo"
        )
        _ = try writePlist("com.docker.socket", in: daemonDir, name: "com.docker.socket")
        try Data("not a plist".utf8).write(to: userDir.appendingPathComponent("README.txt"))
        _ = try writePlist(nil, programArguments: ["/bin/sleep"], in: userDir, name: "nolabel")
        _ = try writePlist("cn.mingcui.mackit.helper", in: daemonDir, name: "cn.mingcui.mackit.helper")

        // The canned launchctl answers: the user-domain dump enables
        // Foo's agent, the system dump disables Docker's socket.
        let launchctl: LaunchctlRun = { arguments in
            switch arguments.first {
            case "print-disabled" where arguments.contains("gui/501"):
                return "\"com.example.foo\" => enabled"
            case "print-disabled" where arguments.contains("system"):
                return "\"com.docker.socket\" => disabled"
            default:
                return nil
            }
        }

        let items = await LoginItemScanner.scan(
            directories: [(.userAgent, userDir.path), (.systemDaemon, daemonDir.path)],
            launchctl: launchctl,
            apps: [InstalledApp(name: "Foo", bundleID: "com.example.foo", version: "1", path: "/Applications/Foo.app")],
            legacyItems: []
        )

        #expect(items.count == 2)
        let foo = try #require(items.first { $0.label == "com.example.foo" })
        #expect(foo.kind == .userAgent)
        #expect(foo.isEnabled)
        #expect(foo.app == MatchedApp(name: "Foo", path: "/Applications/Foo.app"))

        let docker = try #require(items.first { $0.label == "com.docker.socket" })
        #expect(docker.kind == .systemDaemon)
        #expect(!docker.isEnabled)
        #expect(docker.needsHelper)
    }

    @Test func legacyItemsJoinTheScan() async throws {
        let empty = try makeDirectory("scan-legacy-empty")
        // A fixture Mackit.app so the own-item filter has a real bundle
        // id to read (a dangling path would have none).
        let ownApp = try makeDirectory("scan-legacy-own").appendingPathComponent("Mackit.app")
        let contents = ownApp.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "cn.mingcui.mackit"],
            format: .xml,
            options: 0
        )
        try info.write(to: contents.appendingPathComponent("Info.plist"))

        let items = await LoginItemScanner.scan(
            directories: [(.userAgent, empty.path)],
            launchctl: { _ in nil },
            apps: [],
            legacyItems: [
                LegacyLoginItems.Item(path: "/Applications/Notes.app", displayName: "Notes"),
                // Mackit's own app in the login list is filtered.
                LegacyLoginItems.Item(path: ownApp.path, displayName: "Mackit")
            ]
        )

        #expect(items.count == 1)
        #expect(items[0].kind == .legacyLoginItem)
        #expect(items[0].label == "Notes")
        #expect(items[0].plistPath == nil)
        #expect(items[0].targetPath == "/Applications/Notes.app")
        // A legacy entry is its own enabled state.
        #expect(items[0].isEnabled)
    }
}
