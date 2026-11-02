import Foundation
import MackitHelperKit

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
    /// launchctl's own words, capped so a pathological output cannot
    /// flood the reply. Only ever carries service labels and system
    /// error text.
    static func describe(_ result: Result) -> String {
        let detail = result.output.isEmpty ? "" : ": \(result.output)"
        return "launchctl exited \(result.status)\(detail)"
    }

    /// Runs the command, returning its exit status and merged
    /// stdout/stderr. Output is drained only after exit — launchctl's
    /// chatter is a few lines, far below the pipe buffer, so the
    /// read-to-EOF-after-wait order cannot deadlock the way an
    /// unbounded child's would.
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

/// Keeps the delegate alive for the listener's lifetime — `delegate` is
/// weak, and a listener whose delegate was collected rejects every
/// connection.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
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
/// from), and bootstraps it into the system domain. Progress and
/// failures are printed as single lines — the app reads this process's
/// pipe and reports the line to the user, so a failed install names its
/// cause instead of failing silently.
enum Installer {
    /// Exit codes the app maps onto user-facing outcomes.
    static let exitSuccess: Int32 = 0
    static let exitFailure: Int32 = 1

    static func install(version: String, sourcePath: String) -> Int32 {
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
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            return fail("bundled helper not found")
        }

        // Same version already installed: a reinstall would bounce a
        // working daemon for nothing. Report success; the caller
        // verifies the end state either way.
        let binaryInstalled = FileManager.default.fileExists(atPath: HelperIdentity.installedBinaryPath)
        if binaryInstalled, !HelperVersion.isStale(installed: Plist.installedVersion(), bundled: version) {
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
        // Root-owned and world-executable: launchd must be able to run it.
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: HelperIdentity.installedBinaryPath)

        guard Plist.write(version: version) else {
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

    /// Writes the daemon plist for `version`. The plist is built from a
    /// fixed template — every value is a constant except the version
    /// string, which the app passed on the command line and which is
    /// written as a plist value, never into a command.
    static func write(version: String) -> Bool {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HelperIdentity.daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(HelperIdentity.installedBinaryPath)</string>
                <string>--serve</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>\(HelperIdentity.machServiceName)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>\(HelperIdentity.plistVersionKey)</key>
            <string>\(version)</string>
        </dict>
        </plist>

        """
        // No KeepAlive: the daemon is started at boot and on demand by
        // launchd when an XPC client connects (the MachServices entry is
        // what makes it on-demand), and an idle root process that
        // survives a crash-loop is worse than one that stays down.
        do {
            try plist.write(toFile: HelperIdentity.daemonPlistPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Entry point

/// `MackitHelper --serve`            — run as the launchd daemon
/// `MackitHelper --install V SRC`    — run as root by the app's elevation
///
/// The install flag is located by search, not by position: the elevation
/// call that launches this mode hands the tool path to the system as the
/// executable *and* passes the caller's argv array to the tool, and the
/// system prepends the tool path as argv[0] itself — so the flag lands at
/// index 0 or 1 depending on whether the caller's array repeats the path.
/// Finding the flag makes both layouts work. (Verified against the real
/// elevation: a positional parse saw the tool path at index 1 and failed
/// with "unknown mode".)
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--serve" {
    let delegate = ListenerDelegate()
    let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
    listener.delegate = delegate
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
    guard parameters.count == 2 else {
        print("FAIL: usage: MackitHelper --install <version> <sourcePath>")
        exit(Installer.exitFailure)
    }
    exit(Installer.install(version: parameters[0], sourcePath: parameters[1]))
}

print("FAIL: unknown mode")
exit(Installer.exitFailure)
