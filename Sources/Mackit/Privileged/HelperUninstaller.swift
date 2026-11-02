import Foundation
import MackitHelperKit

/// Removes the privileged helper by running it once as root.
///
/// The XPC uninstall (`HelperClient.uninstall`) is the normal path — the
/// daemon answers, deletes its own files and exits, with no password.
/// This is the path for when it cannot answer: a broken install whose
/// daemon never came up has nothing to reply, and the files are
/// root-owned either way, so the removal elevates a one-shot run of the
/// bundled helper through the same primitive the install uses. Without
/// it, a broken install could be neither repaired nor removed — every
/// toggle and every removal would fail with no way out.
///
/// The end state is verified on disk after the elevated process exits:
/// the run's word is trusted only when both files are actually gone.
enum HelperUninstaller {
    /// Runs the privileged removal.
    ///
    /// Blocking for as long as the password dialog is up, so callers run
    /// it off the main actor.
    static func uninstall() -> ElevatedHelper.Outcome {
        // The bundled helper is the one the elevation call launches; it
        // removes the *installed* copy and the daemon plist by their
        // fixed paths.
        guard ElevatedHelper.bundledHelperPath() != nil else {
            return .failed(L10n.tr("loginItems.helper.notBundled"))
        }

        let outcome = ElevatedHelper.run(mode: "--uninstall")

        guard case .notInstalled = HelperClient.installedState() else {
            if let reason = outcome.failureMessage {
                return .failed(L10n.fmt("loginItems.helper.removeFailed", reason))
            }
            return outcome == .cancelled
                ? .cancelled
                : .failed(L10n.tr("loginItems.helper.removeIncomplete"))
        }
        return .succeeded
    }
}
