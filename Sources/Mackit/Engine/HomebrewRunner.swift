import Foundation

/// Runs Homebrew's CLI and captures its output.
///
/// The read-only companion to `CleanEngine`'s command-line cleaning: the
/// inspector queries state through it and `HomebrewActions` drives cleanup
/// through it, and both are testable because the runner itself is injectable.
///
/// The subprocess plumbing mirrors `CleanEngine.runCommand` on purpose —
/// concurrent pipe draining (a 64KB pipe buffer fills and deadlocks the child
/// if the parent only waits for exit), a hard timeout, and cooperative
/// cancellation — but returns plain stdout instead of a `CleanOutcome`, since
/// nothing here deletes anything.
enum HomebrewRunner {
    /// Runs the resolved `brew` executable with `arguments`, returning trimmed
    /// stdout. Nil when brew is not installed, fails to launch, exits nonzero,
    /// or exceeds `timeout` — callers treat every one of those as "no data".
    static func run(_ arguments: [String], timeout: Duration = .seconds(120)) async -> String? {
        guard let brew = ToolLocator.resolve("brew") else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = arguments
        // brew's own shims and ruby expect the login shell's PATH; the same
        // search path CleanEngine injects, so both paths resolve tools alike.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ToolLocator.expandedSearchPaths.joined(separator: ":")
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            MackitLog.brew.error("brew failed to launch: \(arguments.joined(separator: " "), privacy: .public), \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Both pipes drained concurrently, exactly like CleanEngine: waiting
        // for exit before reading deadlocks against a child blocked on write.
        let outputBox = SendablePipe(pipe: outputPipe)
        let errorBox = SendablePipe(pipe: errorPipe)
        let outputTask = Task.detached(priority: .utility) {
            outputBox.pipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached(priority: .utility) {
            errorBox.pipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Cleanup can run for minutes, but never unbounded: the timeout is a
        // parameter so the read queries stay snappy and the actions get the
        // same 600-second ceiling CleanEngine's cleaning uses.
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }

        let exitStatus = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                // The process may have exited before the handler was set, in
                // which case the handler never fires — check once explicitly.
                if !process.isRunning {
                    continuation.resume(returning: process.terminationStatus)
                }
            }
        } onCancel: {
            process.terminate()
        }
        timeoutTask.cancel()

        let outputData = await outputTask.value
        let errorData = await errorTask.value

        guard exitStatus == 0 else {
            let detail = text(from: errorData)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            MackitLog.brew.error("brew exited \(exitStatus): \(arguments.joined(separator: " "), privacy: .public), \(detail.prefix(200), privacy: .public)")
            return nil
        }

        return text(from: outputData)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stdout/stderr as text; nil when the bytes are not valid UTF-8.
    private static func text(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }
}
