import Foundation

/// A continuation that can be resumed exactly once, no matter how many
/// racing paths try to resume it.
///
/// Both subprocess runners install a `Process.terminationHandler` and then
/// check `isRunning` once explicitly, because a process that exited before
/// the handler was set never invokes it. But a process exiting *between*
/// those two statements fires both paths — the handler and the explicit
/// fallback — and a second `resume` on a `CheckedContinuation` traps the
/// process. The window is instructions wide, yet every brew query passes
/// through it, so a guard is cheaper than the crash lottery. The first
/// status wins; a late second resume is a no-op.
///
/// Shared by every subprocess runner in the app — `CleanEngine`'s
/// command-line cleaning and the Homebrew manager's queries and actions.
final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Never>?

    init(_ continuation: CheckedContinuation<Int32, Never>) {
        self.continuation = continuation
    }

    func resume(returning status: Int32) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        // Resumed outside the lock: resume runs the awaiting code, and
        // holding the lock across it would deadlock any thread that tries
        // to resume in the meantime.
        continuation?.resume(returning: status)
    }
}
