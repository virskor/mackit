import Foundation
import MackitHelperKit

/// What one helper call produced.
///
/// A `failure` string rather than Swift's `Result`: the failure modes
/// here are user-facing sentences (the install step's own `FAIL:` line,
/// a lost connection, a timeout), and the codebase already carries
/// outcomes this way — see `HomebrewOutcome`.
struct HelperOutcome: Equatable, Sendable {
    /// A trimmed diagnostic when the call failed; nil on success.
    let failure: String?
    /// Whether the failure was the helper being unreachable — no
    /// installed daemon answered — rather than a refused operation.
    /// An unreachable helper whose files are still in place is a broken
    /// install, and the install flow can repair it by reinstalling.
    let unreachable: Bool

    var succeeded: Bool { failure == nil }

    static let success = HelperOutcome(failure: nil, unreachable: false)

    static func failed(_ message: String, unreachable: Bool = false) -> HelperOutcome {
        HelperOutcome(
            failure: message.isEmpty ? L10n.tr("loginItems.helper.actionFailed") : message,
            unreachable: unreachable
        )
    }
}

/// The app's side of the privileged-helper connection.
///
/// One connection per call: the helper is demand-launched by launchd on
/// the first connection and stays up afterwards, so a persistent
/// connection would only be state to keep alive across page switches for
/// no gain. Each call builds its own connection, and a connection that
/// dies before replying (helper removed mid-call, launchd refused the
/// service) resolves the call as a failure rather than hanging it.
///
/// The installed state is read straight from the daemon plist — no
/// connection needed — so the page can tell "not installed" from
/// "installed" without waking a root process.
enum HelperClient {
    /// What the helper's on-disk footprint says about the installation.
    enum InstalledState: Equatable, Sendable {
        case notInstalled
        case installed(version: String)

        /// Whether a current install is in place. A missing binary or a
        /// missing version record reads as not installed — the plist
        /// without its binary is a broken install, and the install step
        /// replaces it wholesale.
        var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    /// Reads the installed state from the daemon plist and the installed
    /// binary's presence.
    static func installedState() -> InstalledState {
        let binaryExists = FileManager.default.fileExists(atPath: HelperIdentity.installedBinaryPath)
        let plist = NSDictionary(contentsOfFile: HelperIdentity.daemonPlistPath)
        let version = plist?[HelperIdentity.plistVersionKey] as? String
        guard binaryExists, let version, !version.isEmpty else { return .notInstalled }
        return .installed(version: version)
    }

    /// Whether the installed helper was built from a different app
    /// version than the one running. A stale helper is replaced by the
    /// install step, which the model triggers before applying a change.
    static func isInstalledVersionStale(against appVersion: String) -> Bool {
        guard case .installed(let version) = installedState() else { return true }
        return HelperVersion.isStale(installed: version, bundled: appVersion)
    }

    // MARK: - Commands

    /// Enables or disables one system service through the helper.
    static func setSystemService(label: String, plistPath: String, enabled: Bool) async -> HelperOutcome {
        await call { connection, finish in
            guard let proxy = connection.remoteObjectProxy as? MackitHelperProtocol else {
                finish(.failed(L10n.tr("loginItems.helper.unreachable"), unreachable: true))
                return
            }
            // The XPC reply block carries (succeeded, diagnostic); the
            // adapter turns it into the outcome the caller expects.
            let reply: (Bool, String?) -> Void = { succeeded, message in
                finish(succeeded ? .success : .failed(message ?? ""))
            }
            if enabled {
                proxy.enableSystemService(label: label, plistPath: plistPath, withReply: reply)
            } else {
                proxy.disableSystemService(label: label, withReply: reply)
            }
        }
    }

    /// Removes the helper itself: its daemon plist, its binary, and its
    /// launchd registration. The daemon exits once it has replied.
    static func uninstall() async -> HelperOutcome {
        await call { connection, finish in
            guard let proxy = connection.remoteObjectProxy as? MackitHelperProtocol else {
                finish(.failed(L10n.tr("loginItems.helper.unreachable"), unreachable: true))
                return
            }
            let reply: (Bool, String?) -> Void = { succeeded, message in
                finish(succeeded ? .success : .failed(message ?? ""))
            }
            proxy.uninstallHelper(withReply: reply)
        }
    }

    /// Runs one XPC round-trip against a fresh privileged connection.
    ///
    /// The reply, the connection's invalidation and a timeout all race to
    /// resolve the same continuation through a once-guard — an XPC reply
    /// block fires exactly once, but a connection that dies before
    /// replying never fires it at all, and a daemon that hangs would
    /// never fire it either.
    private static func call(
        _ body: @escaping (NSXPCConnection, @escaping (HelperOutcome) -> Void) -> Void
    ) async -> HelperOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<HelperOutcome, Never>) in
            let once = OnceOutcome(continuation)
            let connection = NSXPCConnection(
                machServiceName: HelperIdentity.machServiceName,
                // The helper is a system daemon in the system bootstrap
                // namespace; only the privileged lookup reaches it.
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: MackitHelperProtocol.self)
            connection.invalidationHandler = {
                once.finish(.failed(L10n.tr("loginItems.helper.connectionLost"), unreachable: true))
            }
            connection.resume()

            // Backstop: a daemon that accepts the connection and then
            // never replies would otherwise park the caller forever. The
            // task is cancelled by `finish`, so an answered call does
            // not leave a timer holding the once-guard for 30 seconds
            // after the fact.
            let backstop = Task {
                try? await Task.sleep(for: .seconds(30))
                once.finish(.failed(L10n.tr("loginItems.helper.timeout"), unreachable: true))
            }

            let finish: (HelperOutcome) -> Void = { outcome in
                backstop.cancel()
                connection.invalidate()
                once.finish(outcome)
            }
            body(connection, finish)
        }
    }

    /// Resolves a continuation exactly once. `@unchecked Sendable`
    /// because the guard is an `NSLock`, the same pattern
    /// `OnceContinuation` uses for process exits.
    private final class OnceOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: CheckedContinuation<HelperOutcome, Never>

        init(_ continuation: CheckedContinuation<HelperOutcome, Never>) {
            self.continuation = continuation
        }

        func finish(_ outcome: HelperOutcome) {
            lock.lock()
            let shouldFinish = !finished
            finished = true
            lock.unlock()
            guard shouldFinish else { return }
            continuation.resume(returning: outcome)
        }
    }
}
