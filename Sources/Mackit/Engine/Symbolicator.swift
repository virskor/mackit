import Foundation

/// One frame after symbolication.
struct SymbolizedFrame: Sendable, Hashable, Identifiable {
    let address: UInt64
    /// The resolved symbol, or nil when this frame could not be resolved.
    let symbol: String?

    var id: UInt64 { address }
}

/// Why a record could not be symbolized. Each case is a different sentence
/// in the UI — the difference between "the binary is gone" and "the binary
/// was replaced by an update" is the difference between a shrug and a
/// warning that the symbols on screen would be wrong.
enum SymbolicationUnavailable: Sendable, Hashable {
    /// The record carries no image range, so there is nothing to check the
    /// frames against. Only a record written by an older collector.
    case noImageRange
    /// Not one frame belongs to Mackit's own image.
    case noOwnFrames
    /// The executable the record names is no longer on disk.
    case binaryMissing
    /// The executable is there, but it is a different build: symbolizing an
    /// old record against a new binary produces confident nonsense.
    case binaryReplaced(recorded: String, current: String)
    /// `atos` itself failed to run or exited nonzero.
    case atosFailed
}

/// The outcome of symbolicating one record: every frame in the record's
/// order, with symbols filled in where they could be resolved.
struct SymbolicationResult: Sendable, Hashable {
    let frames: [SymbolizedFrame]
    let unavailableReason: SymbolicationUnavailable?
}

/// Turns a record's frame addresses into symbols with `atos`.
///
/// The record stores the main executable's runtime image range, which is
/// what makes this possible at all: `atos` can only resolve an address
/// against the binary that address lives in, and a backtrace mixes our
/// frames with system ones. Frames outside the recorded range are left as
/// addresses — resolved against the wrong binary they would come back as
/// confident garbage, which is worse than an honest address.
///
/// Refuses on purpose when the binary at the recorded path is a different
/// build: after an update the path still exists but holds new code, and
/// every symbol it produced for an old record would be wrong.
enum Symbolicator {
    /// `atos` resolves tens of addresses in milliseconds; this ceiling is
    /// for a wedged system, not for real work.
    static let timeout: Duration = .seconds(15)

    /// The system symbolizer. A fixed path, like `/usr/bin/log`: it ships
    /// with the OS and CrashReporter itself calls it.
    static let executablePath = "/usr/bin/atos"

    /// Symbolicates `entry`'s frames. Never throws: every failure is a
    /// `SymbolicationUnavailable` reason with the frames left as addresses.
    static func symbolicate(_ entry: CrashLogEntry) async -> SymbolicationResult {
        let unresolved = SymbolicationResult(
            frames: entry.frames.map { SymbolizedFrame(address: $0, symbol: nil) },
            unavailableReason: nil
        )
        guard let header = entry.imageHeader, let end = entry.imageEnd, end > header else {
            return SymbolicationResult(frames: unresolved.frames, unavailableReason: .noImageRange)
        }
        let ownFrames = framesInImage(entry.frames, header: header, end: end)
        guard !ownFrames.isEmpty else {
            return SymbolicationResult(frames: unresolved.frames, unavailableReason: .noOwnFrames)
        }
        guard !entry.executablePath.isEmpty,
              FileManager.default.fileExists(atPath: entry.executablePath) else {
            return SymbolicationResult(frames: unresolved.frames, unavailableReason: .binaryMissing)
        }
        guard !isDifferentBuild(entry) else {
            return SymbolicationResult(
                frames: unresolved.frames,
                unavailableReason: .binaryReplaced(recorded: entry.appVersion, current: currentVersion)
            )
        }
        guard let output = await runATOS(
            executable: entry.executablePath, loadAddress: header, addresses: ownFrames
        ) else {
            return SymbolicationResult(frames: unresolved.frames, unavailableReason: .atosFailed)
        }
        var symbols: [UInt64: String] = [:]
        for (address, symbol) in zip(ownFrames, parseOutput(output)) {
            if let symbol { symbols[address] = symbol }
        }
        return SymbolicationResult(
            frames: entry.frames.map { SymbolizedFrame(address: $0, symbol: symbols[$0]) },
            unavailableReason: nil
        )
    }

    /// The frames that fall inside the recorded image range. Pure, so the
    /// boundary behavior is tested without a subprocess.
    static func framesInImage(_ frames: [UInt64], header: UInt64, end: UInt64) -> [UInt64] {
        frames.filter { $0 >= header && $0 < end }
    }

    /// Parses `atos`'s output into one entry per input address, in order.
    ///
    /// An address `atos` cannot resolve comes back as the address itself,
    /// echoed in the form the arguments were passed in: with a
    /// "(in Mackit)" tail when the address is inside the image, bare when it
    /// is outside it. Both spellings start with `0x` — the form
    /// `runATOS` always passes — so a line that starts with the address is
    /// an echo and maps to nil, never to a "symbol" that is the address
    /// again. Anything else is the symbol text, kept verbatim: `atos`
    /// formats it as `symbol (in binary) (file:line)` and the file and line
    /// are exactly what a reader wants.
    static func parseOutput(_ output: String) -> [String?] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                // An echo of the address, not a symbol. A real symbol name
                // never starts with a digit, so this cannot swallow one.
                if trimmed.hasPrefix("0x") { return nil }
                return trimmed
            }
    }

    // MARK: - Internals

    /// Whether the binary now at the record's path is a different build
    /// than the one that crashed.
    private static func isDifferentBuild(_ entry: CrashLogEntry) -> Bool {
        guard !entry.appVersion.isEmpty, !entry.build.isEmpty else { return false }
        return entry.appVersion != currentVersion || entry.build != currentBuild
    }

    /// The running binary's version and build. The "0" fallback is the
    /// collector's, deliberately: the two sides read the same keys, and
    /// disagreeing on the missing-value placeholder would make every record
    /// from a bundle without version info look like a different build.
    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Runs `atos` over `addresses`, bounded by `timeout`. Returns stdout,
    /// or nil when it fails to launch, exits nonzero, or is killed.
    private static func runATOS(
        executable: String,
        loadAddress: UInt64,
        addresses: [UInt64]
    ) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-o", executable, "-l", Formatters.hex(loadAddress)]
            + addresses.map { Formatters.hex($0) }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            MackitLog.fs.error("atos failed to launch: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Both pipes drained concurrently, the discipline every subprocess
        // runner here follows: a child blocked on a full pipe never exits,
        // and a reader that waits for exit before draining never returns.
        let outputBox = SendablePipe(pipe: outputPipe)
        let errorBox = SendablePipe(pipe: errorPipe)
        let outputTask = Task.detached(priority: .utility) {
            outputBox.pipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached(priority: .utility) {
            errorBox.pipe.fileHandleForReading.readDataToEndOfFile()
        }

        let exitStatus = await wait(for: process)
        let outputData = await outputTask.value
        _ = await errorTask.value

        guard exitStatus == 0 else {
            MackitLog.fs.error("atos exited \(exitStatus, privacy: .public)")
            return nil
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    /// Waits for `process`, killing it if it outlives the timeout. The
    /// once-guarded continuation is the shared pattern: a process that
    /// exits between the handler install and the explicit check would
    /// otherwise resume twice and trap.
    private static func wait(for process: Process) async -> Int32 {
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
}
