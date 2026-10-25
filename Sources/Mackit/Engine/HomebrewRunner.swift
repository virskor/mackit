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
        guard let launched = launch(arguments) else { return nil }

        // Both pipes drained concurrently, exactly like CleanEngine: waiting
        // for exit before reading deadlocks against a child blocked on write.
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
            let detail = text(from: errorData)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            MackitLog.brew.error("brew exited \(exitStatus): \(arguments.joined(separator: " "), privacy: .public), \(detail.prefix(200), privacy: .public)")
            return nil
        }

        return text(from: outputData)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs an action and reports every output line as it arrives, for the
    /// progress the page shows while brew works.
    ///
    /// Both streams are reported: once stdout is a pipe brew sends the
    /// download headings to stderr, so a log built from stdout alone would go
    /// quiet for the whole download phase and read as a hang. Returns the
    /// merged text — the same nil outcomes as `run`.
    static func stream(
        _ arguments: [String],
        timeout: Duration = .seconds(600),
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> String? {
        guard let launched = launch(arguments) else { return nil }

        let collector = LineCollector()
        let outputBox = SendablePipe(pipe: launched.output)
        let errorBox = SendablePipe(pipe: launched.error)
        // The pumps read to EOF, which the process exiting guarantees — so
        // they run alongside the wait rather than before it: awaiting them
        // first would leave a hung brew's pipes open forever and the timeout
        // unreachable.
        async let pumping: Void = withTaskGroup(of: Void.self) { group in
            group.addTask { await pump(outputBox, onLine: onLine, into: collector) }
            group.addTask { await pump(errorBox, onLine: onLine, into: collector) }
        }

        let exitStatus = await wait(for: launched.process, timeout: timeout)
        await pumping

        guard exitStatus == 0 else {
            MackitLog.brew.error("brew exited \(exitStatus): \(arguments.joined(separator: " "), privacy: .public)")
            return nil
        }

        return collector.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the brew process: the resolved executable, the arguments, and a
    /// PATH brew's own shims and ruby can resolve tools through.
    private static func launch(_ arguments: [String]) -> (process: Process, output: Pipe, error: Pipe)? {
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
        return (process, outputPipe, errorPipe)
    }

    /// Waits for the process to exit, terminating it if it outlives `timeout`
    /// or the awaiting task is cancelled. Returns the status either way.
    private static func wait(for process: Process, timeout: Duration) async -> Int32 {
        // Cleanup can run for minutes, but never unbounded: the timeout is a
        // parameter so the read queries stay snappy and the actions get the
        // same 600-second ceiling CleanEngine's cleaning uses.
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }

        let exitStatus = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                // Once-wrapped: a process exiting between the handler install
                // and the isRunning check below would fire both resume paths,
                // and a double resume traps.
                let once = OnceContinuation(continuation)
                process.terminationHandler = { process in
                    once.resume(returning: process.terminationStatus)
                }
                // The process may have exited before the handler was set, in
                // which case the handler never fires — check once explicitly.
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

    /// Reads one pipe to EOF, reporting each complete line as it arrives. The
    /// trailing partial line is reported too — brew's last line often has no
    /// newline after it.
    private static func pump(
        _ box: SendablePipe,
        onLine: @MainActor @Sendable (String) -> Void,
        into collector: LineCollector
    ) async {
        var lines = LineBuffer()
        while true {
            let chunk = box.pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            for line in lines.append(chunk) {
                collector.append(line)
                await onLine(line)
            }
        }
        if let tail = lines.flush() {
            collector.append(tail)
            await onLine(tail)
        }
    }

    /// Stdout/stderr as text; nil when the bytes are not valid UTF-8.
    private static func text(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }
}

/// Accumulates the merged output while both pipes pump. Lock-guarded because
/// the two readers report lines independently and finish at different moments.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// Splits a byte stream into lines.
///
/// A chunk boundary can fall mid-line — a pipe read rarely lands on a
/// newline — so the trailing partial line is carried into the next chunk and
/// only flushed once the stream ends (brew's last line often has no newline
/// after it).
struct LineBuffer {
    private var buffer = Data()
    private static let newline = Data("\n".utf8)

    /// Appends a chunk, returning every line it completed. Blank lines are
    /// dropped: brew separates its sections with them, and an empty row in
    /// the log says nothing.
    mutating func append(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let range = buffer.range(of: Self.newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    /// The trailing partial line, once the stream has ended.
    mutating func flush() -> String? {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8), !tail.isEmpty else {
            return nil
        }
        return tail
    }
}
