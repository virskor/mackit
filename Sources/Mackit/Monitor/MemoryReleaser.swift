import AppKit

/// The result of a memory release.
enum MemoryReleaseOutcome: Equatable {
    /// The amount of memory released (bytes).
    case released(Int64)
    /// Execution succeeded, but free memory did not change — the system was not under pressure to begin with.
    case noChange
    /// The user cancelled in the system authorization dialog.
    case cancelled
    /// Failed, with the description returned by AppleScript.
    case failed(String)
}

/// Memory release: run purge with administrator privileges.
///
/// purge clears the disk buffer cache (file cache), returning pages to the
/// free pool; anonymous memory allocated by apps is unaffected. Execution by
/// an unprivileged process is rejected outright by the kernel, so it must go
/// through `with administrator privileges` — the authorization dialog is
/// presented by the system and its title carries this app's name, so the
/// user can clearly see which app is asking for the password.
///
/// Not switching to launching osascript via `Process`: then the dialog would
/// show as osascript instead of this app, leaving the user no way to tell who
/// is requesting elevated privileges.
enum MemoryReleaser {
    /// The absolute path of purge. An authorized shell does not guarantee that /usr/sbin is in PATH.
    static let purgeCommand = "/usr/sbin/purge"

    /// The error number AppleScript returns when the user cancels in the authorization dialog.
    static let cancelledErrorNumber = -128

    /// The AppleScript source for privileged execution.
    ///
    /// The command accepts only the `purgeCommand` constant: this script runs
    /// as root, so once callers are allowed to concatenate strings, it opens a
    /// door for command injection. Tests that need to verify the script
    /// content can read this constant and assemble the same sentence directly.
    static func script() -> String {
        "do shell script \"\(purgeCommand)\" with administrator privileges"
    }

    /// Execute a piece of AppleScript, returning (error message, error number); both are nil on success.
    ///
    /// Must be called on the main thread, for the same reason as `release`.
    @MainActor
    static func run(_ source: String) -> (message: String?, number: Int?) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return (nil, nil) }
        return (
            error[NSAppleScript.errorMessage] as? String,
            (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        )
    }

    /// Perform a memory release: take a baseline → execute → take it again; the difference is the released amount.
    ///
    /// `run` and `memoryFree` are injectable for testing. The whole function is
    /// `@MainActor`: the authorization dialog has its own nested event loop, so
    /// while the main thread is blocked inside `run` the UI still responds, but
    /// this also means the execution cannot be moved to a background thread.
    ///
    /// `memoryFree` may return nil (sampling failure). The difference is then
    /// unreliable, so treat it as "no change" — do not make up a released amount.
    @MainActor
    static func release(
        run: @escaping @MainActor (String) -> (message: String?, number: Int?),
        memoryFree: @escaping @MainActor () -> Int64?
    ) -> MemoryReleaseOutcome {
        let before = memoryFree()
        let result = run(script())
        let after = memoryFree()
        let freed = before.flatMap { b in after.map { $0 - b } } ?? 0
        // purge returns the file cache to the free pool; used memory does not
        // change, so the free amount is its only real gain.
        return outcome(freed: freed, message: result.message, number: result.number)
    }

    /// Map the execution result and the free-memory difference across the release into a user-perceivable outcome.
    static func outcome(freed: Int64, message: String?, number: Int?) -> MemoryReleaseOutcome {
        if let message {
            return number == cancelledErrorNumber ? .cancelled : .failed(message)
        }
        return freed > 0 ? .released(freed) : .noChange
    }
}
