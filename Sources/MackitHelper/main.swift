import Darwin
import Foundation
import MackitHelperKit
import os
import Security

// MARK: - Logging

/// The daemon's log. Kept deliberately minimal — counts, states and
/// outcomes only, never file contents or request payloads — and spelled
/// out here rather than shared with the app: the helper is a separate
/// executable and `MackitLog` lives in the app target.
private let helperLog = Logger(subsystem: "cn.mingcui.mackit.helper", category: "daemon")

// MARK: - launchctl execution

/// Runs one validated `LaunchctlCommand` and reports what came back.
///
/// `Process` with an argv array — there is no shell in this path, which is
/// the point: the helper's inputs are a label and a plist path, both
/// validated, and neither ever meets a quoting or escaping question.
enum Launchctl {
    struct Result: Equatable, Sendable {
        let status: Int32
        let output: String

        var succeeded: Bool { status == 0 }
    }

    /// The system launchctl, resolved rather than hardcoded: its
    /// directory differs between macOS layouts, and a hardcoded path
    /// that does not exist turns every command into a launch failure.
    /// See `SystemTool` for the full story.
    static let executable = SystemTool.launchctlPath

    /// A one-line diagnostic from a failed run: the exit status plus
    /// launchctl's own words, truncated so a pathological output cannot
    /// flood the reply. Only ever carries service labels and system
    /// error text.
    static func describe(_ result: Result) -> String {
        let detail = result.output.isEmpty ? "" : ": \(truncated(result.output))"
        return "launchctl exited \(result.status)\(detail)"
    }

    /// The longest launchctl excerpt kept in a diagnostic. launchctl's
    /// own error text is a line or two; anything longer is a dump this
    /// reply has no business carrying.
    private static let maxDetailLength = 200

    private static func truncated(_ text: String) -> String {
        guard text.count > maxDetailLength else { return text }
        return String(text.prefix(maxDetailLength)) + "…"
    }

    /// Runs the command, returning its exit status and merged
    /// stdout/stderr. The pipe is drained to EOF *before* waiting for
    /// exit — the order matters: waiting first would deadlock on any
    /// child that fills the pipe buffer, and launchctl's chatter on a
    /// failure can exceed it.
    @discardableResult
    static func run(_ command: LaunchctlCommand) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = command.arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Result(status: process.terminationStatus, output: text)
    }

    /// Whether the system service is currently loaded. The print probe's
    /// exit status is the answer; its output is not needed.
    static func isLoaded(label: String) -> Bool {
        guard let command = HelperRequest.printCommand(label: label) else { return false }
        return run(command).succeeded
    }
}

// MARK: - XPC service

/// Calls its reply exactly once. An XPC reply block called twice traps,
/// and every early-return path in the handlers below is a second chance
/// to forget — the guard makes the mistake impossible rather than
/// something to keep track of.
final class OnceReply: @unchecked Sendable {
    private let lock = NSLock()
    private var replied = false
    private let block: (Bool, String?) -> Void

    init(_ block: @escaping (Bool, String?) -> Void) {
        self.block = block
    }

    func call(_ succeeded: Bool, _ message: String?) {
        lock.lock()
        let shouldReply = !replied
        replied = true
        lock.unlock()
        guard shouldReply else { return }
        block(succeeded, message)
    }
}

/// The object the XPC connection talks to. Every request is validated
/// before anything runs, and the command set is closed: there is no
/// request this type can serve that is not one of the protocol's three
/// methods, and none of those three executes anything but a validated
/// launchctl invocation or the removal of the helper's own two files.
final class HelperService: NSObject, MackitHelperProtocol {
    func enableSystemService(label: String, plistPath: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let once = OnceReply(reply)
        // Validation is the whole gate: an invalid label or path never
        // reaches launchctl, here or anywhere else.
        guard HelperRequest.enableCommands(label: label, plistPath: plistPath) != nil else {
            once.call(false, "invalid label or plist path")
            return
        }
        // The label and the plist must name the same service: an
        // override recorded for one label while a different daemon is
        // bootstrapped is a change nobody asked for. Every request the
        // app makes pairs the label it read out of a plist with that
        // same plist, so a disagreement means the request is not one
        // the app built.
        guard Plist.label(of: plistPath) == label else {
            once.call(false, "label and plist path name different services")
            return
        }
        // The override must land first: it is the part that survives a
        // reboot, so a failure here means the service would still start
        // at next boot even if the runtime part succeeded.
        let override = Launchctl.run(.enableSystem(label: label))
        guard override.succeeded else {
            once.call(false, Launchctl.describe(override))
            return
        }
        // Already loaded: the enable alone is the whole change.
        guard !Launchctl.isLoaded(label: label) else {
            once.call(true, nil)
            return
        }
        let bootstrap = Launchctl.run(.bootstrapSystem(plistPath: plistPath))
        guard bootstrap.succeeded else {
            // A bootstrap failure can still leave the service loaded —
            // launchd reports an error for an already-bootstrapped
            // service — so the loaded state, not the exit status, is the
            // verdict on whether the enable took effect.
            if Launchctl.isLoaded(label: label) {
                once.call(true, nil)
            } else {
                once.call(false, Launchctl.describe(bootstrap))
            }
            return
        }
        once.call(true, nil)
    }

    func disableSystemService(label: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let once = OnceReply(reply)
        guard HelperRequest.disableCommands(label: label) != nil else {
            once.call(false, "invalid label")
            return
        }
        let override = Launchctl.run(.disableSystem(label: label))
        guard override.succeeded else {
            once.call(false, Launchctl.describe(override))
            return
        }
        // A disabled service keeps running until it is torn down; without
        // the bootout the user would watch the switch do nothing.
        guard Launchctl.isLoaded(label: label) else {
            once.call(true, nil)
            return
        }
        let bootout = Launchctl.run(.bootoutSystem(label: label))
        guard bootout.succeeded else {
            once.call(false, Launchctl.describe(bootout))
            return
        }
        once.call(true, nil)
    }

    func uninstallHelper(withReply reply: @escaping (Bool, String?) -> Void) {
        let once = OnceReply(reply)
        // Order is the whole contract. The bootout tears down this very
        // service — it stops, with a SIGTERM, the process running this
        // method — so everything that must happen first does: delete our
        // own files, then answer the caller, and only then drop the
        // connection. A daemon that booted itself out first died before
        // deleting anything or replying, leaving its files installed,
        // its service unregistered, and the caller with a dropped
        // connection and no way to remove it.
        let fileManager = FileManager.default
        for path in [HelperIdentity.daemonPlistPath, HelperIdentity.installedBinaryPath] {
            // Missing files are the success case — uninstalling twice is
            // not an error.
            try? fileManager.removeItem(atPath: path)
        }
        once.call(true, nil)
        // The reply needs a moment on the wire before the connection's
        // other end goes away. The bootout (or the exit below, whichever
        // lands first) is what ends it, and everything is already done.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            _ = Launchctl.run(.bootoutSystem(label: HelperIdentity.daemonLabel))
            exit(0)
        }
    }
}

/// The code-signing requirement this daemon enforces on its clients,
/// resolved once at startup from the daemon plist the install wrote.
///
/// The helper runs as root and its Mach service is reachable by every
/// local process, so "any process may ask" is not an acceptable trust
/// boundary: without a requirement, any unprivileged process could
/// disable arbitrary system daemons as root. The requirements are the
/// designated requirements of the app installs that have installed the
/// daemon — each one an identity an administrator authenticated at
/// install time — so the daemon serves exactly those installs, whatever
/// signing identity each carries (Developer ID or an ad-hoc development
/// build).
///
/// nil — and therefore a refusal of every connection — when the plist
/// carries no requirement, or carries one the requirement language
/// cannot parse. An unparseable requirement must fail closed: passing
/// it to `setConnectionCodeSigningRequirement` would raise an
/// exception, and accepting connections without it is the hole being
/// closed. A daemon in that state is repairable by reinstalling, which
/// the app detects as an unreachable helper.
enum ClientRequirement {
    private static let resolved: String? = {
        guard let requirements = Plist.authorizedClientRequirements(),
              HelperRequest.isValidClientRequirements(requirements) else {
            return nil
        }
        let joined = HelperRequest.joinedClientRequirement(requirements)
        // Parse the joined expression here, once, where a failure is a
        // refusal rather than an exception inside the XPC machinery.
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(joined as CFString, [], &requirement) == errSecSuccess else {
            return nil
        }
        return joined
    }()

    /// The requirement to apply to a new connection, or nil when this
    /// daemon must refuse every connection.
    static var current: String? { resolved }
}

/// Keeps the delegate alive for the listener's lifetime — `delegate` is
/// weak, and a listener whose delegate was collected rejects every
/// connection.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // The gate when the daemon plist carries no usable requirement:
        // refuse every connection. With a valid requirement in place
        // this method is never reached for a non-matching client — the
        // listener-level requirement (set in the serve mode below)
        // rejects those before the delegate is consulted.
        guard ClientRequirement.current != nil else {
            helperLog.error("refusing XPC connection: no valid client requirements in daemon plist")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: MackitHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

// MARK: - Install / uninstall modes

/// The `--install` mode, run once as root by the app's elevation call.
///
/// It copies the bundled helper into `/Library/PrivilegedHelperTools`,
/// writes the daemon plist (recording the app version it was installed
/// from and adding the installing app to the authorized-client list its
/// clients must satisfy), and bootstraps it into the system domain.
/// Progress and failures are printed as single lines — the app reads
/// this process's pipe and reports the line to the user, so a failed
/// install names its cause instead of failing silently.
enum Installer {
    /// Exit codes the app maps onto user-facing outcomes.
    static let exitSuccess: Int32 = 0
    static let exitFailure: Int32 = 1

    static func install(version: String, sourcePath: String, clientRequirement: String) -> Int32 {
        func fail(_ message: String) -> Int32 {
            print("FAIL: \(message)")
            fflush(stdout)
            return exitFailure
        }

        // The source must be the bundled helper. Anything else — a copy
        // of the binary at some arbitrary path — is refused: only the
        // app's own bundle has standing to install itself system-wide.
        guard HelperRequest.isBundledHelperPath(sourcePath) else {
            return fail("source path is not the bundled helper")
        }
        guard isInsideAppBundle(sourcePath) else {
            return fail("source path is not inside an app bundle")
        }
        // The final path component must be the regular file itself, not
        // a symlink: the copy follows links, so a link aimed at a
        // root-only file would land its contents in a world-readable
        // file under /Library.
        guard isRegularFile(sourcePath) else {
            return fail("bundled helper is not a regular file")
        }
        guard HelperRequest.isValidVersion(version) else {
            return fail("invalid version")
        }
        guard HelperRequest.isValidClientRequirement(clientRequirement) else {
            return fail("invalid client requirement")
        }
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            return fail("bundled helper not found")
        }

        // Same version already installed *and the daemon is loaded*: a
        // reinstall would bounce a working daemon for nothing. Report
        // success; the caller verifies the end state either way. The
        // loaded check is the whole point — files with a dead daemon is
        // the broken-install state, and skipping it here is what used to
        // leave that state unrepairable.
        let binaryInstalled = FileManager.default.fileExists(atPath: HelperIdentity.installedBinaryPath)
        let daemonLoaded = Launchctl.isLoaded(label: HelperIdentity.daemonLabel)
        let plan = HelperInstall.plan(
            binaryExists: binaryInstalled,
            versionStale: HelperVersion.isStale(installed: Plist.installedVersion(), bundled: version),
            daemonLoaded: daemonLoaded
        )
        if plan == .skip {
            print("OK: already installed")
            fflush(stdout)
            return exitSuccess
        }

        let fileManager = FileManager.default
        let toolsDirectory = (HelperIdentity.installedBinaryPath as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: toolsDirectory, withIntermediateDirectories: true)
        } catch {
            return fail("cannot create \(toolsDirectory): \(error.localizedDescription)")
        }

        // Replace, don't merge: a leftover binary from a previous
        // version would keep serving requests after the plist moved on.
        try? fileManager.removeItem(atPath: HelperIdentity.installedBinaryPath)
        do {
            try fileManager.copyItem(atPath: sourcePath, toPath: HelperIdentity.installedBinaryPath)
        } catch {
            return fail("cannot copy helper: \(error.localizedDescription)")
        }
        // Root-owned and world-executable: launchd must be able to run
        // it, and the user who happened to be logged in when the install
        // ran must not be able to rewrite the daemon's code. The copy
        // preserves the source's owner, so ownership is set explicitly
        // and verified — a user-writable root daemon is a standing
        // privilege-escalation invitation.
        do {
            try fileManager.setAttributes(
                [.ownerAccountName: "root", .groupOwnerAccountName: "wheel"],
                ofItemAtPath: HelperIdentity.installedBinaryPath
            )
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: HelperIdentity.installedBinaryPath)
        } catch {
            try? fileManager.removeItem(atPath: HelperIdentity.installedBinaryPath)
            return fail("cannot set helper ownership: \(error.localizedDescription)")
        }
        guard installedBinaryIsRootOwned() else {
            try? fileManager.removeItem(atPath: HelperIdentity.installedBinaryPath)
            return fail("installed helper is not root-owned")
        }

        guard Plist.write(
            version: version,
            clientRequirements: HelperRequest.authorizedClients(
                existing: Plist.authorizedClientRequirements() ?? [],
                adding: clientRequirement
            )
        ) else {
            return fail("cannot write daemon plist")
        }

        // Replace any daemon already bootstrapped from an older install:
        // bootstrapping a second plist for the same label fails, and the
        // old process would keep the old code alive.
        _ = Launchctl.run(.bootoutSystem(label: HelperIdentity.daemonLabel))
        let bootstrap = Launchctl.run(.bootstrapSystem(plistPath: HelperIdentity.daemonPlistPath))
        guard bootstrap.succeeded else {
            return fail("launchctl bootstrap: \(bootstrap.output)")
        }

        print("OK: installed \(version)")
        fflush(stdout)
        return exitSuccess
    }
}

/// Removes the helper's own footprint, run once as root by the app's
/// elevation call.
///
/// This is the path for a daemon that cannot remove itself: the XPC
/// uninstall needs the daemon alive to answer, and a broken install —
/// files on disk, daemon never bootstrapped — has nothing to answer.
/// The files are root-owned either way, so the app elevates a one-shot
/// run of the bundled helper instead of dead-ending.
///
/// It touches exactly the two paths the install writes, and nothing
/// else: the bootout stops a daemon still running from an older
/// install, and the removals finish whatever the daemon could not.
enum Uninstaller {
    /// Exit codes the app maps onto user-facing outcomes.
    static let exitSuccess: Int32 = 0
    static let exitFailure: Int32 = 1

    static func uninstall() -> Int32 {
        func fail(_ message: String) -> Int32 {
            print("FAIL: \(message)")
            fflush(stdout)
            return exitFailure
        }

        // Bootout first: a daemon still running from an older install
        // holds the mach service and would keep answering connections
        // after the files backing it are gone.
        _ = Launchctl.run(.bootoutSystem(label: HelperIdentity.daemonLabel))

        let fileManager = FileManager.default
        let paths = [HelperIdentity.daemonPlistPath, HelperIdentity.installedBinaryPath]
        for path in paths {
            // Missing files are the success case — uninstalling twice is
            // not an error, and a half-removed install is exactly what
            // this path exists to finish.
            try? fileManager.removeItem(atPath: path)
        }

        let leftovers = paths.filter { fileManager.fileExists(atPath: $0) }
        guard leftovers.isEmpty else {
            return fail("could not remove \(leftovers.joined(separator: ", "))")
        }

        print("OK: uninstalled")
        fflush(stdout)
        return exitSuccess
    }
}

/// Reads and writes the helper's own daemon plist.
enum Plist {
    /// The version recorded in the installed daemon plist, or nil when
    /// the plist is missing or holds no version.
    static func installedVersion() -> String? {
        guard let dict = NSDictionary(contentsOfFile: HelperIdentity.daemonPlistPath) as? [String: Any] else {
            return nil
        }
        return dict[HelperIdentity.plistVersionKey] as? String
    }

    /// The authorized-client requirements the installed daemon enforces,
    /// or nil when the plist carries none.
    static func authorizedClientRequirements() -> [String]? {
        guard let dict = NSDictionary(contentsOfFile: HelperIdentity.daemonPlistPath) as? [String: Any] else {
            return nil
        }
        return dict[HelperIdentity.authorizedClientRequirementsKey] as? [String]
    }

    /// The `Label` a daemon plist declares, or nil when the plist is
    /// unreadable or carries none. The enable path checks it against the
    /// label it was asked to override.
    static func label(of path: String) -> String? {
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        return dict["Label"] as? String
    }

    /// Writes the daemon plist for `version` and the authorized-client
    /// `requirements`.
    ///
    /// The plist is built as a dictionary and serialized, never as an
    /// interpolated string: a value spliced into XML can close its own
    /// element and open another, which turns a version string into a
    /// launchd configuration directive (EnvironmentVariables and friends
    /// are real keys). Serialization makes that structurally impossible
    /// — every value is a value.
    static func write(version: String, clientRequirements: [String]) -> Bool {
        let plist: [String: Any] = [
            "Label": HelperIdentity.daemonLabel,
            "ProgramArguments": [HelperIdentity.installedBinaryPath, "--serve"],
            "MachServices": [HelperIdentity.machServiceName: true],
            // No KeepAlive: the daemon is started at boot and on demand
            // by launchd when an XPC client connects (the MachServices
            // entry is what makes it on-demand), and an idle root process
            // that survives a crash-loop is worse than one that stays
            // down.
            "RunAtLoad": true,
            HelperIdentity.plistVersionKey: version,
            HelperIdentity.authorizedClientRequirementsKey: clientRequirements,
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: URL(fileURLWithPath: HelperIdentity.daemonPlistPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// The install step's checks on its own source path.
extension Installer {
    /// Whether `path` sits inside an app bundle that identifies itself
    /// as Mackit. The suffix test (`isBundledHelperPath`) alone would
    /// accept a planted copy at any matching path; the bundle's own
    /// Info.plist is the part that cannot be faked by dropping a binary
    /// in /tmp.
    static func isInsideAppBundle(_ path: String) -> Bool {
        let marker = "/" + HelperIdentity.bundleRelativePath
        guard let range = path.range(of: marker, options: .backwards) else { return false }
        let bundlePath = String(path[path.startIndex..<range.lowerBound])
        guard !bundlePath.isEmpty else { return false }
        let infoPath = (bundlePath as NSString).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOfFile: infoPath) as? [String: Any] else { return false }
        return dict["CFBundleIdentifier"] as? String == HelperIdentity.appBundleID
    }

    /// Whether `path` is a regular file, not a symlink or a directory —
    /// the copy follows links, and a link aimed at a root-only file
    /// would copy that file's contents into a world-readable location.
    static func isRegularFile(_ path: String) -> Bool {
        // lstat, not `attributesOfItem`: the latter follows the link and
        // reports the *target's* type, which is the one thing here that
        // must not be trusted.
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Whether the installed binary is owned by root, read from the
    /// filesystem rather than assumed. The install verifies it instead
    /// of trusting the setAttributes call.
    static func installedBinaryIsRootOwned() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: HelperIdentity.installedBinaryPath) else {
            return false
        }
        return attributes[.ownerAccountName] as? String == "root"
    }
}

// MARK: - Entry point

/// `MackitHelper --serve`                  — run as the launchd daemon
/// `MackitHelper --install V SRC REQ`      — run as root by the app's elevation
/// `MackitHelper --uninstall`              — run as root by the app's elevation
///
/// The one-shot flags are located by search, not by position: the
/// elevation call that launches these modes hands the tool path to the
/// system as the executable *and* passes the caller's argv array to the
/// tool, and the system prepends the tool path as argv[0] itself — so a
/// flag lands at index 0 or 1 depending on whether the caller's array
/// repeats the path. Finding the flag makes both layouts work.
/// (Verified against the real elevation: a positional parse saw the
/// tool path at index 1 and failed with "unknown mode".)
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--serve" {
    let delegate = ListenerDelegate()
    let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
    listener.delegate = delegate
    // The gate, applied at the listener rather than per connection: a
    // client whose code signature does not satisfy the requirement is
    // rejected before the delegate is consulted. The requirement is
    // resolved once (and pre-parsed) at startup; without a valid one
    // the listener stays ungated and the delegate refuses every
    // connection, because a root daemon serving unauthenticated
    // callers is the state this design exists to prevent.
    if let requirement = ClientRequirement.current {
        listener.setConnectionCodeSigningRequirement(requirement)
    } else {
        helperLog.error("daemon plist carries no valid client requirements; refusing every connection")
    }
    listener.resume()
    // The delegate must outlive the assignment: `delegate` is a weak
    // property on the listener, and a released delegate makes the
    // listener reject every connection — the daemon would sit there
    // healthy-looking while every call failed. `withExtendedLifetime`
    // pins it for the whole (never-returning) run.
    withExtendedLifetime(delegate) {
        // Never returns: the daemon's lifetime is launchd's business.
        dispatchMain()
    }
}

if let flagIndex = arguments.firstIndex(of: "--install") {
    let parameters = Array(arguments.dropFirst(flagIndex + 1))
    guard parameters.count == 3 else {
        print("FAIL: usage: MackitHelper --install <version> <sourcePath> <clientRequirement>")
        exit(Installer.exitFailure)
    }
    exit(Installer.install(version: parameters[0], sourcePath: parameters[1], clientRequirement: parameters[2]))
}

// The uninstall mode carries no arguments, so presence is the whole
// invocation. It runs the bundled copy — the one the elevation call
// launches — which is why it can remove the installed one.
if arguments.contains("--uninstall") {
    exit(Uninstaller.uninstall())
}

print("FAIL: unknown mode")
exit(Installer.exitFailure)
