import Foundation
import Testing

@testable import Mackit
@testable import MackitHelperKit

/// The privileged helper's trust boundary: request validation, the argv
/// vectors it builds, and the version comparison the install check runs.
///
/// These are the rules that keep a root process safe — a request that
/// fails validation never reaches launchctl — so they are pinned here
/// rather than left to the daemon's runtime behavior.
struct MackitHelperKitTests {
    // MARK: Label validation

    @Test func acceptsWellFormedLabels() {
        #expect(HelperRequest.isValidLabel("com.docker.socket"))
        #expect(HelperRequest.isValidLabel("88L2Q4487U.com.tencent.WeWorkMac.IPCHelper"))
        #expect(HelperRequest.isValidLabel("Dev.ServBay.macOS.ServBay.Helper"))
        #expect(HelperRequest.isValidLabel("a"))
    }

    @Test func rejectsMalformedLabels() {
        // Empty and over-long.
        #expect(!HelperRequest.isValidLabel(""))
        #expect(!HelperRequest.isValidLabel(String(repeating: "a", count: HelperRequest.maxLabelLength + 1)))
        // Shell metacharacters and path separators: the label is an argv
        // element, but a launchd label with these has no legitimate
        // existence either.
        #expect(!HelperRequest.isValidLabel("com.example.service; rm -rf /"))
        #expect(!HelperRequest.isValidLabel("com.example.service && launchctl"))
        #expect(!HelperRequest.isValidLabel("com.example/service"))
        #expect(!HelperRequest.isValidLabel("com.example service"))
        #expect(!HelperRequest.isValidLabel("$(whoami)"))
        #expect(!HelperRequest.isValidLabel("com.example.service`id`"))
        #expect(!HelperRequest.isValidLabel("com.example|service"))
    }

    // MARK: Plist path validation

    @Test func acceptsDaemonPlists() {
        #expect(HelperRequest.isValidSystemPlistPath("/Library/LaunchDaemons/com.docker.socket.plist"))
        #expect(HelperRequest.isValidSystemPlistPath("/Library/LaunchDaemons/a.plist"))
        #expect(HelperRequest.isValidSystemPlistPath("/Library/LaunchDaemons/Dev.ServBay.macOS.ServBay.Helper.plist"))
    }

    @Test func rejectsPathsOutsideTheDaemonsDirectory() {
        // The helper manages system daemons only.
        #expect(!HelperRequest.isValidSystemPlistPath("/Library/LaunchAgents/com.example.plist"))
        #expect(!HelperRequest.isValidSystemPlistPath("~/Library/LaunchAgents/com.example.plist"))
        #expect(!HelperRequest.isValidSystemPlistPath("/etc/com.example.plist"))
        // Wrong kind, traversal, and a bare directory.
        #expect(!HelperRequest.isValidSystemPlistPath("/Library/LaunchDaemons/com.example"))
        #expect(!HelperRequest.isValidSystemPlistPath("/Library/LaunchDaemons/../LaunchAgents/x.plist"))
        #expect(!HelperRequest.isValidSystemPlistPath("/Library/LaunchDaemons/.plist"))
        #expect(!HelperRequest.isValidSystemPlistPath("/Library/LaunchDaemons/"))
    }

    @Test func acceptsOnlyTheBundledHelperAsInstallSource() {
        #expect(HelperRequest.isBundledHelperPath(
            "/Applications/Mackit.app/Contents/Library/PrivilegedHelperTools/MackitHelper"
        ))
        #expect(HelperRequest.isBundledHelperPath(
            "/Users/someone/Applications/Mackit.app/Contents/Library/PrivilegedHelperTools/MackitHelper"
        ))
        // A copy of the binary anywhere else has no standing.
        #expect(!HelperRequest.isBundledHelperPath("/Library/PrivilegedHelperTools/MackitHelper"))
        #expect(!HelperRequest.isBundledHelperPath("/tmp/MackitHelper"))
        #expect(!HelperRequest.isBundledHelperPath(
            "/Applications/Mackit.app/Contents/MacOS/MackitHelper"
        ))
    }

    // MARK: Command construction

    @Test func enableCommandsBuildTheOverrideThenTheBootstrap() throws {
        let commands = try #require(HelperRequest.enableCommands(
            label: "com.docker.socket",
            plistPath: "/Library/LaunchDaemons/com.docker.socket.plist"
        ))
        #expect(commands == [
            .enableSystem(label: "com.docker.socket"),
            .bootstrapSystem(plistPath: "/Library/LaunchDaemons/com.docker.socket.plist")
        ])
    }

    @Test func disableCommandsBuildTheOverrideThenTheBootout() throws {
        let commands = try #require(HelperRequest.disableCommands(label: "com.docker.socket"))
        #expect(commands == [
            .disableSystem(label: "com.docker.socket"),
            .bootoutSystem(label: "com.docker.socket")
        ])
    }

    @Test func invalidRequestsBuildNoCommands() {
        #expect(HelperRequest.enableCommands(label: "bad label", plistPath: "/Library/LaunchDaemons/x.plist") == nil)
        #expect(HelperRequest.enableCommands(label: "good.label", plistPath: "/Library/LaunchAgents/x.plist") == nil)
        #expect(HelperRequest.disableCommands(label: "bad/label") == nil)
        #expect(HelperRequest.printCommand(label: "bad label") == nil)
    }

    @Test func argvVectorsMatchLaunchctlsShape() {
        #expect(LaunchctlCommand.enableSystem(label: "com.docker.socket").arguments
            == ["enable", "system/com.docker.socket"])
        #expect(LaunchctlCommand.disableSystem(label: "com.docker.socket").arguments
            == ["disable", "system/com.docker.socket"])
        #expect(LaunchctlCommand.bootstrapSystem(plistPath: "/Library/LaunchDaemons/x.plist").arguments
            == ["bootstrap", "system", "/Library/LaunchDaemons/x.plist"])
        #expect(LaunchctlCommand.bootoutSystem(label: "com.docker.socket").arguments
            == ["bootout", "system/com.docker.socket"])
        #expect(LaunchctlCommand.printSystem(label: "com.docker.socket").arguments
            == ["print", "system/com.docker.socket"])
    }

    // MARK: System tool resolution

    @Test func launchctlResolvesToAPathThatExists() {
        // The whole point of the resolution: the binary's directory
        // differs between macOS layouts, and a hardcoded path that does
        // not exist turns every launchctl call into a launch failure.
        // Whatever this machine carries, the resolved path must be real
        // and must be one of the two system candidates.
        let path = SystemTool.launchctlPath
        #expect(path == "/usr/bin/launchctl" || path == "/bin/launchctl")
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))
    }

    // MARK: Version comparison

    @Test func staleVersionsComparePositionally() {
        #expect(HelperVersion.compare("1.2.3", "1.2.3") == .orderedSame)
        #expect(HelperVersion.compare("1.2.3", "1.2.4") == .orderedAscending)
        #expect(HelperVersion.compare("1.3", "1.2.9") == .orderedDescending)
        #expect(HelperVersion.compare("2", "10") == .orderedAscending)
        // A missing component reads as zero.
        #expect(HelperVersion.compare("1.2", "1.2.0") == .orderedSame)
        // A non-numeric component compares as zero rather than failing.
        #expect(HelperVersion.compare("1.beta", "1.0") == .orderedSame)
    }

    @Test func stalenessDrivesReinstalls() {
        // Missing record: a fresh machine or a hand-deleted plist.
        #expect(HelperVersion.isStale(installed: nil, bundled: "1.2.3"))
        // Same version: current.
        #expect(!HelperVersion.isStale(installed: "1.2.3", bundled: "1.2.3"))
        // Older or newer than the app: the helper's behavior ships with
        // the app, so either direction is a mismatch worth replacing.
        #expect(HelperVersion.isStale(installed: "1.2.2", bundled: "1.2.3"))
        #expect(HelperVersion.isStale(installed: "1.3.0", bundled: "1.2.3"))
    }

    // MARK: Install plan

    @Test func theInstallIsSkippedOnlyWhenTheDaemonAnswers() {
        // Files in place, version current, daemon loaded: a reinstall
        // would bounce a working daemon for nothing.
        #expect(HelperInstall.plan(binaryExists: true, versionStale: false, daemonLoaded: true) == .skip)
    }

    @Test func aDeadDaemonForcesTheInstallEvenAtTheSameVersion() {
        // The broken-install state: files and version record match, but
        // the daemon never came up. A version-only check reads this as
        // "already installed" and skips the bootstrap that would bring
        // the daemon back — which is what left every toggle failing with
        // no way out. The loaded check is what makes a reinstall a
        // repair.
        #expect(HelperInstall.plan(binaryExists: true, versionStale: false, daemonLoaded: false) == .install)
    }

    @Test func aMissingBinaryOrStaleVersionForcesTheInstall() {
        #expect(HelperInstall.plan(binaryExists: false, versionStale: false, daemonLoaded: true) == .install)
        #expect(HelperInstall.plan(binaryExists: true, versionStale: true, daemonLoaded: true) == .install)
        #expect(HelperInstall.plan(binaryExists: false, versionStale: true, daemonLoaded: false) == .install)
    }

    // MARK: Install input validation

    /// The version lands in the daemon plist as a value (the plist is
    /// serialized, so no value can escape its element) — but a string
    /// that is not a version means the caller is not the app, and the
    /// install refuses it rather than recording it.
    @Test func onlyVersionShapesPassValidation() {
        #expect(HelperRequest.isValidVersion("1.0.16"))
        #expect(HelperRequest.isValidVersion("0"))
        #expect(HelperRequest.isValidVersion("2.0.0-beta.1"))
        #expect(!HelperRequest.isValidVersion(""))
        #expect(!HelperRequest.isValidVersion("1.0.16 </string><key>EnvironmentVariables</key>"))
        #expect(!HelperRequest.isValidVersion("1.0\n16"))
        #expect(!HelperRequest.isValidVersion("1.0; rm -rf /"))
        #expect(!HelperRequest.isValidVersion(String(repeating: "1", count: 65)))
    }

    /// The client requirement is the daemon's whole trust boundary, so
    /// it is bounded and single-line: a requirement-language sentence
    /// (identifier, anchor, cdhash) passes, and anything carrying control
    /// characters or absurd length does not.
    @Test func onlyRequirementShapesPassValidation() {
        #expect(HelperRequest.isValidClientRequirement("identifier \"cn.mingcui.mackit\" and anchor apple generic"))
        #expect(HelperRequest.isValidClientRequirement(
            "identifier \"cn.mingcui.mackit\" and anchor apple generic and certificate leaf[subject.OU] = \"TEAMID\""))
        #expect(HelperRequest.isValidClientRequirement("cdhash H\"8c6d11a9e87b365e8ddd3954ac6b32ba5ce91e52\""))
        #expect(!HelperRequest.isValidClientRequirement(""))
        #expect(!HelperRequest.isValidClientRequirement("identifier \"x\"\nand anchor apple generic"))
        #expect(!HelperRequest.isValidClientRequirement("identifier \"x\"\u{7}"))
        #expect(!HelperRequest.isValidClientRequirement(String(repeating: "a", count: 513)))
    }

    /// The authorized-client list: non-empty, within the ceiling, every
    /// entry a valid requirement.
    @Test func theClientListIsBoundedAndValidated() {
        #expect(HelperRequest.isValidClientRequirements(["identifier \"a\""]))
        #expect(HelperRequest.isValidClientRequirements(
            Array(repeating: "identifier \"a\"", count: HelperRequest.maxAuthorizedClients)))
        #expect(!HelperRequest.isValidClientRequirements([]))
        #expect(!HelperRequest.isValidClientRequirements(
            Array(repeating: "identifier \"a\"", count: HelperRequest.maxAuthorizedClients + 1)))
        #expect(!HelperRequest.isValidClientRequirements(["identifier \"a\"", "bad\nrequirement"]))
    }

    /// The join is a parenthesized OR, so one alternative's own `and`
    /// clauses cannot bind across the `or`.
    @Test func theClientListJoinsAsParenthesizedAlternatives() {
        #expect(HelperRequest.joinedClientRequirement(["identifier \"a\""]) == "(identifier \"a\")")
        #expect(HelperRequest.joinedClientRequirement(["identifier \"a\"", "cdhash H\"ff\""])
            == "(identifier \"a\") or (cdhash H\"ff\")")
    }

    /// An install appends its own requirement to the recorded list
    /// instead of replacing it: a release build in /Applications and a
    /// development build elsewhere share one daemon, and a
    /// single-entry list would make each install lock the other out —
    /// every toggle in the app that did not install last would read as
    /// an unreachable helper and trigger a reinstall that locked the
    /// first one out in turn.
    @Test func anInstallAppendsItsRequirementInsteadOfReplacing() {
        let release = "identifier \"cn.mingcui.mackit\" and anchor apple generic"
        let dev = "cdhash H\"8c6d11a9e87b365e8ddd3954ac6b32ba5ce91e52\""

        let afterDev = HelperRequest.authorizedClients(existing: [], adding: dev)
        #expect(afterDev == [dev])

        let afterRelease = HelperRequest.authorizedClients(existing: afterDev, adding: release)
        #expect(afterRelease == [dev, release], "the release install keeps the dev entry authorized")

        // Re-installing the same app dedupes rather than duplicating: the
        // entry moves to the end (order is irrelevant — the daemon ORs
        // the list) and the membership is unchanged.
        let reinstalled = HelperRequest.authorizedClients(existing: afterRelease, adding: dev)
        #expect(reinstalled.count == 2, "a re-install must not duplicate the entry")
        #expect(Set(reinstalled) == Set(afterRelease), "the same two installs stay authorized")
    }

    /// The ceiling evicts the oldest, and the evicted entry comes back
    /// the moment its app reinstalls — the cap costs a repair, never a
    /// lockout.
    @Test func theCeilingEvictsTheOldestAndReinstallsReAdd() {
        let entries = (1...(HelperRequest.maxAuthorizedClients + 2)).map { "identifier \"app\($0)\"" }
        var clients: [String] = []
        for entry in entries {
            clients = HelperRequest.authorizedClients(existing: clients, adding: entry)
        }
        #expect(clients.count == HelperRequest.maxAuthorizedClients)
        #expect(!clients.contains(entries[0]), "the oldest entry is evicted at the ceiling")
        #expect(clients.last == entries.last, "the installing app is always authorized")

        let reinstalled = HelperRequest.authorizedClients(existing: clients, adding: entries[0])
        #expect(reinstalled.contains(entries[0]), "an evicted app re-authorizes itself by reinstalling")
    }
}
