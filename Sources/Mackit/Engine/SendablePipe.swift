import Foundation

/// `Pipe` is not marked `Sendable`, but reading from `fileHandleForReading`
/// is thread-safe; declared explicitly so a child process's stdout and
/// stderr can be drained concurrently in detached tasks (waiting for exit
/// before reading deadlocks against a child blocked on a full pipe buffer).
///
/// Shared by every subprocess runner in the app — `CleanEngine`'s
/// command-line cleaning and the Homebrew manager's queries and actions.
struct SendablePipe: @unchecked Sendable {
    let pipe: Pipe
}
