import Foundation
import MackitHelperKit

/// Installs the privileged helper by running it once as root.
///
/// The install mode is a one-shot run of the bundled helper through the
/// shared elevation primitive (`ElevatedHelper`): as root it copies
/// itself to `/Library/PrivilegedHelperTools`, writes its daemon plist
/// and bootstraps it — and it re-bootstraps even when the version
/// already matches, because files on disk with a dead daemon is a
/// broken install the reinstall exists to repair.
///
/// The end state is verified on disk after the elevated process exits:
/// the pipe's word is trusted only when the plist and binary are
/// actually there.
enum HelperInstaller {
    /// Runs the privileged install.
    ///
    /// Blocking for as long as the password dialog is up, so callers run
    /// it off the main actor.
    static func install() -> ElevatedHelper.Outcome {
        guard let bundledPath = ElevatedHelper.bundledHelperPath() else {
            return .failed(L10n.tr("loginItems.helper.notBundled"))
        }

        let outcome = ElevatedHelper.run(
            mode: "--install",
            // The version to record and the source path the root process
            // copies from — the install refuses any source that is not
            // the bundled helper.
            arguments: [appVersion(), bundledPath]
        )

        // The end state is the verdict: a helper that reported FAIL
        // while the files are in place is a success — that is what the
        // app will talk to — and one that reported OK but left nothing
        // behind is a failure.
        guard case .installed = HelperClient.installedState() else {
            if let reason = outcome.failureMessage {
                return .failed(L10n.fmt("loginItems.helper.installFailed", reason))
            }
            return outcome == .cancelled
                ? .cancelled
                : .failed(L10n.tr("loginItems.helper.installIncomplete"))
        }
        return .succeeded
    }

    /// The running app's version, recorded into the helper's daemon
    /// plist so a later version can tell a stale install from a current
    /// one. Falls back to "0" when the bundle carries no version — a
    /// development binary — which reads as stale against any recorded
    /// version and triggers a reinstall, the safe direction.
    private static func appVersion() -> String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return "0"
        }
        return version
    }
}
