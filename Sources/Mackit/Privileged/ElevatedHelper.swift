import Darwin
import Foundation
import MackitHelperKit
import Security

/// Runs the bundled privileged helper once as root.
///
/// The elevation call is `AuthorizationExecuteWithPrivileges` — the
/// mechanism that launches a tool as root after the standard
/// administrator-password dialog, reached through `dlsym` because the
/// symbol is deprecated since 10.7 and this project builds with zero
/// warnings. It is still present and functional in current macOS; the
/// supported replacement (SMJobBless) needs a stable signing identity,
/// which a plain `swift build` / ad-hoc-signed development build does
/// not have, and the helper's whole job is one narrow launchctl command
/// set that does not warrant a signing-identity dependency.
///
/// Both helper lifecycle operations share this one primitive: the
/// install (`--install`) and the uninstall (`--uninstall`) differ only
/// in the mode flag and its arguments. The uninstall needs root just as
/// much as the install does — the daemon removes its own files when it
/// answers over XPC, but a broken install has no daemon to answer, and
/// the files are root-owned either way.
///
/// The tool the call launches is the bundled helper itself, in one of
/// its one-shot modes. Everything it does is reported back through the
/// communications pipe as one `OK` / `FAIL: reason` line, which this
/// runner reads and maps onto an outcome — a failed run names its cause
/// instead of failing silently.
///
/// There is no shell anywhere in this path: the tool path and its argv
/// are passed as C strings directly, so no quoting or escaping question
/// arises.
enum ElevatedHelper {
    /// What one elevated run produced.
    enum Outcome: Equatable, Sendable {
        case succeeded
        /// The user dismissed the password dialog — not an error worth
        /// an alarming tone, but the operation did not happen.
        case cancelled
        case failed(String)

        /// The diagnostic of a failed run; nil when it succeeded or was
        /// cancelled.
        var failureMessage: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// Runs the bundled helper as root in `mode` with `arguments`.
    ///
    /// Blocking for as long as the password dialog is up, so callers run
    /// it off the main actor. The caller verifies the end state on disk
    /// afterwards — the pipe's word is trusted only when the files
    /// actually agree.
    static func run(mode: String, arguments: [String] = []) -> Outcome {
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

        // argv[0] is the tool path, then the mode and its arguments —
        // the array is NULL-terminated as C expects.
        //
        // The elevation call prepends the tool path as argv[0] itself, so
        // the tool sees the path twice; the helper locates its mode by
        // search rather than by position, which makes both layouts work.
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(bundledPath), strdup(mode)]
        for argument in arguments {
            argv.append(strdup(argument))
        }
        argv.append(nil)
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
        // The run's own verdict, when it failed: the `FAIL:` line names
        // the cause. A run that reported nothing is a success — both
        // one-shot modes print an `OK` line on the way out.
        if let reason = failureLine(output) {
            return .failed(reason)
        }
        return .succeeded
    }

    // MARK: - Pieces

    /// The bundled helper's path, or nil when the app is not running
    /// from a bundle — a plain `.build` executable has nothing to
    /// elevate, and saying so beats failing inside the elevation.
    static func bundledHelperPath() -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent(HelperIdentity.bundleRelativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.path
    }

    /// Resolves the deprecated elevation function at runtime. nil when
    /// the symbol is gone, which every macOS this app runs on still
    /// carries — a nil result fails the run with a real message rather
    /// than a crash.
    private static func executeWithPrivileges(
        _ authorization: AuthorizationRef,
        toolPath: String,
        argv: [UnsafeMutablePointer<CChar>?],
        pipe: UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus {
        /// The C signature of the deprecated elevation call, resolved at
        /// runtime.
        typealias ExecuteWithPrivileges = @convention(c) (
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
        let rtlDefault = UnsafeMutableRawPointer(bitPattern: -2)

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
    /// makes the run synchronous.
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
