import Darwin
import Foundation

/// Bounds how long a child process may run: SIGTERM when the timeout expires,
/// SIGKILL a grace period later.
///
/// `Process.terminate()` alone does not bound a wait. A child that ignores
/// SIGTERM — blocked in uninterruptible IO on a stalled network mount, a wedged
/// `launchctl`, a brew stuck on a lock — keeps its pipes open, and every reader
/// waiting on those pipes blocks with it: `readDataToEndOfFile` and
/// `availableData` only return at EOF. The caller then hangs forever behind a
/// "timeout" it passed in good faith. The SIGKILL is what actually ends the
/// call, because the kernel closes the descriptors when the process dies.
///
/// One component for both subprocess call sites (the brew runner and the
/// command-line cleaner): they share the same plumbing on purpose, and the
/// escalation is the part that must not drift between them.
enum ProcessTimeout {
    /// How long a child gets to honour the SIGTERM before it is killed
    /// outright. Long enough for an orderly shutdown, short enough that a hung
    /// clean still comes back.
    static let killGrace: Duration = .seconds(5)

    /// The task that enforces `timeout` on `process`. The caller cancels it
    /// once the process has exited on its own, so a healthy run never pays the
    /// grace period.
    ///
    /// `killGrace` is a parameter so a test can watch the escalation without
    /// waiting out the production grace; the default is what both call sites
    /// use.
    ///
    /// The cancellation guards matter: `try?` on `Task.sleep` swallows the
    /// cancellation error, so without them a cancelled enforcement would fall
    /// straight through and signal a child the caller had already let go.
    static func enforce(
        _ timeout: Duration,
        on process: Process,
        killGrace: Duration = ProcessTimeout.killGrace
    ) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, process.isRunning else { return }
            process.terminate()
            try? await Task.sleep(for: killGrace)
            guard !Task.isCancelled, process.isRunning else { return }
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }
}
