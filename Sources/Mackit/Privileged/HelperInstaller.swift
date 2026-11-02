import Darwin
import Foundation
import MackitHelperKit
import Security

/// Installs the privileged helper by running it once as root.
///
/// The elevation call is `AuthorizationExecuteWithPrivileges` — the
/// mechanism that launches a tool as root after the standard
/// administrator-password dialog, reached through `dlsym` because the
/// symbol is deprecated since 10.7 and this project builds with zero
/// warnings. It is still present and functional in current macOS; the
/// supported replacement (SMJobBless) needs a stable signing identity,
/// which a plain `swift build` / ad-hoc-signed development build does not
/// have, and the helper's whole job is one narrow launchctl command set
/// that does not warrant a signing-identity dependency.
///
/// The tool the call launches is the bundled helper itself, in its
/// `--install` mode: as root it copies itself to
/// `/Library/PrivilegedHelperTools`, writes its daemon plist and
/// bootstraps it. Everything it does is reported back through the
/// communications pipe as one `OK` / `FAIL: reason` line, which this
/// installer reads and maps onto a result — a failed install names its
/// cause instead of failing silently.
///
/// There is no shell anywhere in this path: the tool path and its argv
/// are passed as C strings directly, so no quoting or escaping question
/// arises.
enum HelperInstaller {
    /// The C signature of the deprecated elevation call, resolved at
    /// runtime.
    private typealias ExecuteWithPrivileges = @convention(c) (
        AuthorizationRef?,
        UnsafePointer<CChar>?,
        AuthorizationFlags,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    /// `RTLD_DEFAULT`'s documented handle value. Swift's dlfcn overlay
    /// marks the macro unavailable ("structure not supported"), so the
    /// pseudo-handle is spelled out: -2 searches the global scope, which
    /// is what the macro means.
    private nonisolated(unsafe) static let rtlDefault = UnsafeMutableRawPointer(bitPattern: -2)

    /// What the install produced.
    enum Outcome: Equatable, Sendable {
        case installed
        /// The user dismissed the password dialog — not an error worth
        /// an alarming tone, but the install did not happen.
        case cancelled
        case failed(String)
    }

    /// Runs the privileged install.
    ///
    /// Blocking for as long as the password dialog is up, so callers run
    /// it off the main actor. The end state is verified on disk after the
    /// elevated process exits: the pipe's word is trusted only when the
    /// plist and binary are actually there.
    static func install() -> Outcome {
        guard let bundledPath = bundledHelperPath() else {
            return .failed(L10n.tr("loginItems.helper.notBundled"))
        }

        var authorization: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
        guard AuthorizationCreate(nil, nil, flags, &authorization) == errSecSuccess,
              let authorization else {
            return .failed(L10n.tr("loginItems.helper.authorizationFailed"))
        }
        defer { AuthorizationFree(authorization, []) }

        // argv[0] is the tool path, then the install mode and its two
        // arguments — the version to record and the source path the root
        // process copies from. The array is NULL-terminated as C expects.
        //
        // The elevation call prepends the tool path as argv[0] itself, so
        // the tool sees the path twice; the daemon locates `--install` by
        // search rather than by position, which makes both layouts work.
        let version = appVersion()
        let argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(bundledPath), strdup("--install"), strdup(version), strdup(bundledPath), nil
        ]
        defer {
            for argument in argv { free(argument) }
        }

        var pipe: UnsafeMutablePointer<FILE>?
        let status = executeWithPrivileges(authorization, toolPath: bundledPath, argv: argv, pipe: &pipe)
        let output = readAndClose(pipe)

        // A cancelled dialog and a refused authorization are the user's
        // doing, not a failure to report as one.
        if status == errAuthorizationCanceled {
            return .cancelled
        }
        guard status == errSecSuccess else {
            return .failed(L10n.tr("loginItems.helper.elevationFailed"))
        }

        // The install step's own verdict, checked against reality: a
        // helper that reported OK but left no plist behind is a failure,
        // and one that reported FAIL while the files are in place is a
        // success — the end state is what the app will talk to.
        guard case .installed = HelperClient.installedState() else {
            let reason = failureLine(output) ?? L10n.tr("loginItems.helper.installFailed")
            return .failed(reason)
        }
        return .installed
    }

    // MARK: - Pieces

    /// The bundled helper's path, or nil when the app is not running
    /// from a bundle — a plain `.build` executable has nothing to
    /// install from, and saying so beats failing inside the elevation.
    private static func bundledHelperPath() -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent(HelperIdentity.bundleRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }

    /// The running app's version, recorded into the helper's daemon
    /// plist so a later version can tell a stale install from a current
    /// one. Falls back to "0" when the bundle carries no version — a
    /// development binary — which reads as stale against any recorded
    /// version and triggers a reinstall, the safe direction.
    private static func appVersion() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return (version?.isEmpty == false) ? version! : "0"
    }

    /// Resolves the deprecated elevation function at runtime. nil when
    /// the symbol is gone, which every macOS this app runs on still
    /// carries — a nil result fails the install with a real message
    /// rather than a crash.
    private static func executeWithPrivileges(
        _ authorization: AuthorizationRef,
        toolPath: String,
        argv: [UnsafeMutablePointer<CChar>?],
        pipe: UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus {
        guard let symbol = dlsym(rtlDefault, "AuthorizationExecuteWithPrivileges") else {
            return errSecInternalError
        }
        let function = unsafeBitCast(symbol, to: ExecuteWithPrivileges.self)
        return toolPath.withCString { path in
            argv.withUnsafeBufferPointer { buffer in
                // The C parameter is a mutable pointer to the argv
                // vector; the function only reads the vector, so the
                // immutable buffer's address is handed over through the
                // standard mutating cast rather than copied.
                let arguments = UnsafeMutablePointer(mutating: buffer.baseAddress)
                return function(authorization, path, [], arguments, pipe)
            }
        }
    }

    /// Reads the elevated process's output to EOF and closes the pipe.
    /// Reading blocks until the root process exits, which is also what
    /// makes the install synchronous.
    private static func readAndClose(_ pipe: UnsafeMutablePointer<FILE>?) -> String {
        guard let pipe else { return "" }
        var chunks: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = read(fileno(pipe), &buffer, buffer.count)
            if count <= 0 { break }
            chunks.append(contentsOf: buffer[..<count])
        }
        fclose(pipe)
        return String(decoding: chunks, as: UTF8.self)
    }

    /// The reason half of a `FAIL: reason` line, or nil when the output
    /// holds no failure line.
    private static func failureLine(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            if line.hasPrefix("FAIL:") {
                let reason = line.dropFirst("FAIL:".count)
                    .trimmingCharacters(in: .whitespaces)
                return reason.isEmpty ? nil : String(reason)
            }
        }
        return nil
    }
}
