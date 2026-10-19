import Foundation
import AppKit

/// The cleaning result of a single entry.
struct CleanOutcome: Sendable, Identifiable {
    let id: String
    let itemID: String
    let title: String
    let path: String
    let reclaimed: Int64
    let succeeded: Bool
    let message: String
}

/// Events during the cleaning process.
enum CleanEvent: Sendable {
    case started(total: Int)
    case progress(completed: Int, total: Int, current: String)
    case outcome(CleanOutcome)
    case finished(reclaimed: Int64, failures: Int)
}

/// The cleaning engine: delete directories / move to trash / run command-line cleaning.
enum CleanEngine {

    /// Determine whether the app with a given bundle ID is running.
    ///
    /// `NSWorkspace.runningApplications` requires the main thread
    /// (`AppMemorySampler.topApps` is likewise called on the main thread and
    /// documents this), while the cleaning engine runs on a detached task, so
    /// this closure is declared `@MainActor`: when the caller awaits it, it
    /// hops back to the main thread automatically, the same path as
    /// `recycleOnMainActor`. Tests can inject a stand-in.
    static let defaultAppRunningCheck: @MainActor @Sendable (String) -> Bool = { bundleID in
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    static func clean(
        items: [JunkItem],
        moveToTrash: Bool,
        isAppRunning: @escaping @MainActor @Sendable (String) -> Bool = defaultAppRunningCheck
    ) -> AsyncStream<CleanEvent> {
        AsyncStream(CleanEvent.self) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(items: items, moveToTrash: moveToTrash, isAppRunning: isAppRunning, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        items: [JunkItem],
        moveToTrash: Bool,
        isAppRunning: @escaping @MainActor @Sendable (String) -> Bool,
        continuation: AsyncStream<CleanEvent>.Continuation
    ) async {
        continuation.yield(.started(total: items.count))
        var reclaimed: Int64 = 0
        var failures = 0

        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            continuation.yield(.progress(completed: index, total: items.count, current: item.title))
            let outcome = await handle(item, moveToTrash: moveToTrash, isAppRunning: isAppRunning)
            if outcome.succeeded {
                reclaimed += outcome.reclaimed
            } else {
                failures += 1
            }
            continuation.yield(.outcome(outcome))
        }

        continuation.yield(.progress(completed: items.count, total: items.count, current: ""))
        continuation.yield(.finished(reclaimed: reclaimed, failures: failures))
        continuation.finish()
    }

    private static func handle(
        _ item: JunkItem,
        moveToTrash: Bool,
        isAppRunning: @escaping @MainActor @Sendable (String) -> Bool
    ) async -> CleanOutcome {
        if item.isCommand {
            return await runCommand(item)
        }
        // Uninstalling a running app risks losing unsaved work, so it is rejected
        // outright with a message. Associated files (caches, application support,
        // preferences…) are likewise read and written in real time by the running
        // app; deleting them pulls live data out from under the process, so they
        // are rejected too. Residue entries also carry a bundleID, so this is not
        // limited to the .app bundle itself.
        if let bundleID = item.bundleID, await isAppRunning(bundleID) {
            return CleanOutcome(
                id: item.id, itemID: item.id, title: item.title, path: item.path,
                reclaimed: 0, succeeded: false, message: L10n.fmt("clean.error.appRunning", item.title)
            )
        }
        return await remove(item, moveToTrash: moveToTrash)
    }

    // MARK: - File system cleaning

    private static func remove(_ item: JunkItem, moveToTrash: Bool) async -> CleanOutcome {
        guard !item.path.isEmpty else {
            return CleanOutcome(
                id: item.id, itemID: item.id, title: item.title, path: item.path,
                reclaimed: 0, succeeded: false, message: L10n.tr("clean.error.noPath")
            )
        }
        if FileSystem.isProtected(item.path) {
            return CleanOutcome(
                id: item.id, itemID: item.id, title: item.title, path: item.path,
                reclaimed: 0, succeeded: false, message: L10n.tr("clean.error.protected")
            )
        }

        let url = URL(fileURLWithPath: item.path)
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            // It no longer exists: drop this entry from the list, but no space was
            // freed, so the stale size from the scan cannot be counted as "released" —
            // under nested rules the same space would be reported once by each child
            // after the parent deletes it.
            return CleanOutcome(
                id: item.id, itemID: item.id, title: item.title, path: item.path,
                reclaimed: 0, succeeded: true, message: L10n.tr("clean.error.notExist")
            )
        }

        // Re-measure before deleting: the size recorded during the scan may be
        // stale (further writes since, or a parent just deleted part of it), so the
        // total reclaimed is based on the bytes actually deleted.
        let freed = FileSystem.allocatedSize(of: url)

        if moveToTrash {
            let recycled = await recycle(urls: [url])
            if recycled {
                return CleanOutcome(
                    id: item.id, itemID: item.id, title: item.title, path: item.path,
                    reclaimed: freed, succeeded: true, message: L10n.tr("clean.error.trashed")
                )
            }
            // When the trash is unavailable, fail explicitly rather than quietly
            // falling back to permanent deletion: the user choosing "Move to Trash"
            // wants recoverability, and quietly calling removeItem would silently
            // turn that preference into an unrecoverable one.
            return CleanOutcome(
                id: item.id, itemID: item.id, title: item.title, path: item.path,
                reclaimed: 0, succeeded: false, message: L10n.tr("clean.error.trashFailed")
            )
        }

        return await delete(item, url: url, reclaimed: freed)
    }

    /// NSWorkspace's recycle is callback-based; it is wrapped into async/await
    /// here. On newer SDKs it returns Void, so success can only be determined
    /// through the completion handler. NSWorkspace belongs to AppKit and must
    /// be used on the main thread.
    private static func recycle(urls: [URL]) async -> Bool {
        await recycleOnMainActor(urls: urls)
    }

    @MainActor
    private static func recycleOnMainActor(urls: [URL]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            NSWorkspace.shared.recycle(urls) { newURLs, error in
                let succeeded = error == nil && !newURLs.isEmpty
                continuation.resume(returning: succeeded)
            }
        }
    }

    private static func delete(_ item: JunkItem, url: URL, reclaimed: Int64) async -> CleanOutcome {
        do {
            try FileManager.default.removeItem(at: url)
            return CleanOutcome(
                id: item.id, itemID: item.id, title: item.title, path: item.path,
                reclaimed: reclaimed, succeeded: true, message: L10n.tr("clean.error.deleted")
            )
        } catch {
            return CleanOutcome(
                id: item.id, itemID: item.id, title: item.title, path: item.path,
                reclaimed: 0, succeeded: false, message: error.localizedDescription
            )
        }
    }

    // MARK: - Command-line cleaning

    private static func runCommand(_ item: JunkItem) async -> CleanOutcome {
        guard !item.command.isEmpty else {
            return CleanOutcome(
                id: item.id, itemID: item.id, title: item.title, path: "",
                reclaimed: 0, succeeded: false, message: L10n.tr("clean.error.noCommand")
            )
        }

        let executable = ToolLocator.resolve(item.command[0]) ?? item.command[0]
        let arguments = Array(item.command.dropFirst())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Command-line tools often rely on the login shell's PATH, so it is filled in explicitly here.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = CleanEngine.searchPath
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return CleanOutcome(
                id: item.id, itemID: item.id, title: item.title, path: "",
                reclaimed: 0, succeeded: false,
                message: L10n.fmt("clean.error.cannotRun", error.localizedDescription)
            )
        }

        // Both pipes must be drained concurrently; you cannot just wait for the
        // process to exit and read afterwards. Pipe buffers are typically only 64KB:
        // once the child process fills one it blocks on write, and if the parent
        // only waits for the exit, the two wait on each other and deadlock.
        let outputBox = SendablePipe(pipe: outputPipe)
        let errorBox = SendablePipe(pipe: errorPipe)
        let outputTask = Task.detached(priority: .utility) {
            outputBox.pipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached(priority: .utility) {
            errorBox.pipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Command-line cleaning can run for a long time (brew cleanup starts at
        // several minutes), but it must never hang forever: the user clicking "Stop"
        // has to be able to stop it, and a runaway child process needs a backstop.
        // terminationHandler + withTaskCancellationHandler are the double safety
        // net, with the timeout delivering the final blow from another task.
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(Self.commandTimeoutSeconds))
            if process.isRunning { process.terminate() }
        }

        let exitStatus = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                // The process may have already exited before terminationHandler is
                // set, in which case the handler will never be called, so it must be
                // checked once explicitly.
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
            let message = text(from: errorData)
                ?? text(from: outputData)
                ?? L10n.fmt("clean.error.exitCode", Int(exitStatus))
            logCommand(item, executable: executable, exitStatus: exitStatus)
            return CleanOutcome(
                id: item.id, itemID: item.id, title: item.title, path: "",
                reclaimed: 0, succeeded: false,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).description
            )
        }

        logCommand(item, executable: executable, exitStatus: exitStatus)
        return CleanOutcome(
            id: item.id, itemID: item.id, title: item.title, path: "",
            reclaimed: item.size, succeeded: true, message: L10n.tr("clean.error.commandDone")
        )
    }

    /// Debug details of command execution: the full command line and exit code.
    /// The user-facing message on the failure path is logged as an error by the
    /// caller (AppViewModel); only troubleshooting details are left here.
    private static func logCommand(_ item: JunkItem, executable: String, exitStatus: Int32) {
        let command = ([executable] + Array(item.command.dropFirst())).joined(separator: " ")
        if exitStatus == 0 {
            MackitLog.clean.debug("命令成功（\(command, privacy: .public)）")
        } else {
            MackitLog.clean.error("命令失败（\(command, privacy: .public)）：退出码 \(exitStatus)")
        }
    }

    /// The timeout limit for command-line cleaning. Commands like brew cleanup
    /// start at several minutes, but however long they run there must be an end,
    /// or a single cleaning run would hang forever.
    private static let commandTimeoutSeconds: Int = 600

    /// The PATH injected into the child process. Shares the same search path as
    /// `ToolLocator`: the pip3 found in `~/.pyenv/shims` has a shim that itself
    /// relies on PATH to find python, so once the two lists diverge, the command
    /// fails or runs on the wrong interpreter.
    private static let searchPath: String = ToolLocator.expandedSearchPaths.joined(separator: ":")

    private static func text(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// `Pipe` is not marked `Sendable`, but reading from `fileHandleForReading`
/// is thread-safe; it is declared explicitly here so pipes can be drained
/// concurrently in detached tasks.
private struct SendablePipe: @unchecked Sendable {
    let pipe: Pipe
}
