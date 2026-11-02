import Foundation
import MackitHelperKit

/// The injected seam: runs launchctl with arguments, returns trimmed
/// stdout or nil on any failure. Tests substitute a canned map.
typealias LaunchctlRun = @Sendable ([String]) async -> String?

/// Runs `launchctl` and captures its output.
///
/// The subprocess plumbing mirrors `HomebrewRunner` on purpose — the
/// same concurrent pipe draining (a child blocked on write deadlocks a
/// parent that only waits for exit), the same hard timeout through
/// `ProcessTimeout`, the same cooperative cancellation — because the
/// failure mode is identical: launchctl blocked on a wedged launchd
/// would park the caller forever behind a timeout it passed in good
/// faith.
///
/// Unlike the brew runner this one takes a fixed system path resolved by
/// `SystemTool` rather than a PATH search: both candidate directories
/// are system-owned and not user-writable, so there is nothing for a
/// caller to redirect — but which of the two exists differs between
/// macOS layouts, which is why the path is resolved and not hardcoded.
enum LaunchctlRunner {
    /// Runs launchctl with `arguments`, returning trimmed stdout.
    /// nil when launchctl fails to launch, exits nonzero, or exceeds
    /// `timeout` — callers treat every one of those as "no answer".
    static func run(
        _ arguments: [String],
        timeout: Duration = .seconds(30)
    ) async -> String? {
        guard let launched = launch(arguments) else { return nil }

        let outputBox = SendablePipe(pipe: launched.output)
        let errorBox = SendablePipe(pipe: launched.error)
        let outputTask = Task.detached(priority: .utility) {
            outputBox.pipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached(priority: .utility) {
            errorBox.pipe.fileHandleForReading.readDataToEndOfFile()
        }

        let exitStatus = await wait(for: launched.process, timeout: timeout)

        let outputData = await outputTask.value
        let errorData = await errorTask.value

        guard exitStatus == 0 else {
            // A `print` probe's nonzero exit is the answer "not loaded",
            // not a failure — enabling a service that is not loaded is a
            // normal outcome, and logging it as an error would put an
            // error line in the log every time.
            if arguments.first == "print" {
                MackitLog.loginItems.debug("launchctl probe exited \(exitStatus): \(arguments.joined(separator: " "), privacy: .public)")
            } else {
                let detail = text(from: errorData)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                MackitLog.loginItems.error("launchctl exited \(exitStatus): \(arguments.joined(separator: " "), privacy: .public), \(detail.prefix(200), privacy: .public)")
            }
            return nil
        }

        return text(from: outputData)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the launchctl process with both streams piped. The
    /// executable's path is resolved by `SystemTool`, not hardcoded —
    /// see its doc comment for why a single hardcoded path is wrong.
    private static func launch(_ arguments: [String]) -> (process: Process, output: Pipe, error: Pipe)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SystemTool.launchctlPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            MackitLog.loginItems.error("launchctl failed to launch: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return (process, outputPipe, errorPipe)
    }

    /// Waits for the process to exit, terminating it if it outlives
    /// `timeout` or the awaiting task is cancelled.
    private static func wait(for process: Process, timeout: Duration) async -> Int32 {
        let timeoutTask = ProcessTimeout.enforce(timeout, on: process)
        let exitStatus = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                let once = OnceContinuation(continuation)
                process.terminationHandler = { process in
                    once.resume(returning: process.terminationStatus)
                }
                if !process.isRunning {
                    once.resume(returning: process.terminationStatus)
                }
            }
        } onCancel: {
            process.terminate()
        }
        timeoutTask.cancel()
        return exitStatus
    }

    private static func text(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }
}
