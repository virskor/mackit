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

    @Test func staleVersionsComparePositionally() {        #expect(HelperVersion.compare("1.2.3", "1.2.3") == .orderedSame)
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
}
