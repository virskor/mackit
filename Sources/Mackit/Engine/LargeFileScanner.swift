import Foundation
import os

/// One file at or above the scan's size threshold.
struct LargeFile: Identifiable, Sendable, Hashable {
    let path: String
    let name: String
    /// Bytes allocated to the file, as the kernel reports them.
    let size: Int64
    /// Last modification date, or nil when the filesystem would not say.
    let modified: Date?
    /// The directory holding the file, spelled as the traversal spelled it.
    let parentPath: String

    var id: String { path }
}

/// Events while walking the disk for large files.
enum LargeFileScanEvent: Sendable {
    /// One more directory enumerated: the running count and the directory
    /// just visited. Throttled inside the scanner.
    case progress(scanned: Int, current: String)
    /// A file at or above the threshold. Yielded the moment it is found, not
    /// held back for the end of the walk: each hit is a finished fact — its
    /// size is the kernel's current allocation for the file as it exists now
    /// — so presenting it while the walk continues shows nothing that is
    /// still moving. This is the deliberate difference from the disk
    /// analysis, whose tree sizes only stop moving when the whole traversal
    /// lands.
    case found(LargeFile)
    /// The walk is over. `unreadableDirectories` counts the folders the
    /// process could not read at all — without Full Disk Access those hold
    /// files the scan never saw, so the page says so instead of claiming the
    /// list is everything there is. The hit count and byte total are not
    /// carried: the `.found` events already delivered them, in order, and
    /// the scanner logs its own totals.
    case finished(unreadableDirectories: Int)
}

/// Read-only search for large files: walk one directory tree and report every
/// regular file at or above a size threshold.
///
/// Same traversal shape as `DiskAnalyzer` — a fixed pool of workers over one
/// shared queue of directories — minus the tree aggregation: nothing folds
/// into a parent here, because the answer is a flat list of files. The
/// threshold is applied while enumerating, so a whole-disk walk retains only
/// the hits (tens of entries) however many millions of files it passes.
///
/// Safety rules inherited from the disk analysis traversal:
/// - symlinked children are neither followed nor listed — a link's own size
///   is a few dozen bytes, and following one would count its target twice;
/// - mount points are skipped entirely: another volume's bytes belong to that
///   volume's accounting, and a startup-disk walk reaches the data volume's
///   contents through the firmlinks;
/// - `com.apple.*` system data is skipped by `FileSystem.entries`
///   (TCC-protected on macOS 26+);
/// - the volume-root plumbing markers are skipped by name at any depth;
/// - unreadable directories are counted rather than probed.
///
/// Hard links are reported once per path, like the disk analysis reports
/// them: the same vnode reached through two names is two rows. Deduplicating
/// by (device, inode) would under-report what a user sees in Finder, and the
/// totals here are a "what is on disk" figure, not a "what would be freed"
/// one — deleting one name of a hard-linked pair frees nothing, which is a
/// fact the clean flow surfaces per item anyway.
enum LargeFileScanner {
    /// Volume-root plumbing that must not be listed or traversed. Same set,
    /// same reason as the disk analysis: they only ever exist at volume roots
    /// and inside `.nofollow`'s mirror of one.
    private static let systemMarkers: Set<String> = [".nofollow", ".resolve", ".vol", ".file"]

    /// Walk `root`, reporting every regular file at or above `threshold`
    /// bytes. Cancelling the stream's consumer cancels the underlying walk.
    ///
    /// `protectedPaths` are the folders this walk refuses to enter without an
    /// explicit request (the TCC-protected home trio by default): the caller
    /// passes its session's set, the same contract the disk analysis scan
    /// has — a stale default would silently re-skip (or re-enter) folders the
    /// user already decided about.
    static func scan(
        root: String,
        protectedPaths: Set<String>,
        threshold: Int64
    ) -> AsyncStream<LargeFileScanEvent> {
        AsyncStream(LargeFileScanEvent.self) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startedAt = ContinuousClock.now
                let progress = LargeFileProgressGate(continuation)
                let queue = WalkQueue(root: root)
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<ScanEngine.maxConcurrentMeasurements {
                        group.addTask {
                            await walkThroughQueue(
                                queue: queue,
                                protectedPaths: protectedPaths,
                                threshold: threshold,
                                progress: progress
                            )
                        }
                    }
                }
                // A cancelled walk publishes nothing: its partial list would
                // be presented as a finished one.
                if !Task.isCancelled {
                    continuation.yield(.finished(unreadableDirectories: progress.unreadableCount))
                    MackitLog.disk.info(
                        "large-file scan of \(root, privacy: .public): \(progress.foundCount, privacy: .public) files above \(threshold, privacy: .public) bytes, \(progress.foundBytes, privacy: .public) bytes, \(progress.unreadableCount, privacy: .public) unreadable directories, took \(MackitLog.duration(.now - startedAt), privacy: .public)"
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One worker of the walk pool: takes batches of directories off the
    /// shared queue until the walk is over.
    ///
    /// An empty queue is not the end of the walk — another worker may be
    /// mid-enumeration with subdirectories still to push — so a worker that
    /// finds nothing polls briefly instead of exiting, and exits for good
    /// once the queue records that everything discovered has been visited (or
    /// the walk was cancelled). Polling rather than parking on a
    /// continuation keeps a cancelled worker waking up, the same choice the
    /// disk analysis's counting pass makes.
    private static func walkThroughQueue(
        queue: WalkQueue,
        protectedPaths: Set<String>,
        threshold: Int64,
        progress: LargeFileProgressGate
    ) async {
        while !Task.isCancelled {
            guard let batch = await queue.nextBatch() else { return }
            // Subdirectories are collected locally and pushed once per batch
            // rather than once per directory: one lock acquisition per 64
            // directories, with the found children still reaching the other
            // workers well inside the time the batch takes to walk.
            var subdirectories: [String] = []
            for path in batch {
                if Task.isCancelled { break }
                walk(path, protectedPaths: protectedPaths, threshold: threshold, progress: progress, into: &subdirectories)
            }
            queue.push(contentsOf: subdirectories)
            queue.record()
        }
    }

    /// Enumerates one directory: reports its large files and collects its
    /// subdirectories.
    private static func walk(
        _ path: String,
        protectedPaths: Set<String>,
        threshold: Int64,
        progress: LargeFileProgressGate,
        into subdirectories: inout [String]
    ) {
        progress.tick(path)
        guard let entries = FileSystem.entries(of: path) else {
            // Unreadable at all — a denied TCC prompt, a locked folder, or a
            // directory that vanished mid-walk. Counted so the page can say
            // the scan may have missed files rather than claiming the list
            // is everything there is.
            progress.unreadable()
            return
        }
        for entry in entries {
            if systemMarkers.contains(entry.name) { continue }
            // A symlinked child is neither followed nor listed: not followed
            // avoids double-counting the target and cycles; not listed keeps
            // the link's own few dozen bytes from ever passing the threshold.
            if entry.isSymbolicLink { continue }
            if entry.isDirectory {
                // A mount point is another volume: not listed, not counted,
                // not entered (see the type comment).
                if entry.isMountPoint { continue }
                if protectedPaths.contains(entry.path) { continue }
                subdirectories.append(entry.path)
            } else if entry.allocatedSize >= threshold {
                progress.found(LargeFile(
                    path: entry.path,
                    name: entry.name,
                    size: entry.allocatedSize,
                    modified: modificationDate(of: entry.url),
                    parentPath: entry.parentPath
                ))
            }
        }
    }

    /// The file's modification date, read per hit rather than carried in the
    /// shared bulk enumeration: hits are rare (a whole-disk walk finds tens),
    /// and `FileSystem.entries`'s `getattrlistbulk` record carries no
    /// modtime — adding a field to the shared record for a value only these
    /// rare files need would churn code the disk analysis also depends on.
    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// The walk's shared work queue.
///
/// Workers take batches, walk them, and hand the batch back through `record`.
/// A drained queue cannot tell a worker the walk is over on its own — another
/// worker may be mid-enumeration with children still to push — so `working`
/// tracks the workers holding a batch right now, and only an empty queue with
/// none of them busy ends the walk. Same shape, and same reasoning, as the
/// disk analysis counting pass's queue.
///
/// A lock rather than an actor: `push` runs once per batch, and the actor hop
/// is cheap at that rate, but `nextBatch`'s take-and-count must be one
/// atomic step — a worker that took a batch without yet counting itself busy
/// would let another conclude the walk is over and exit with that batch's
/// subdirectories never walked.
private final class WalkQueue: Sendable {
    private struct State {
        var pending: [String] = []
        /// Workers holding a batch right now — between taking one and handing
        /// its result back. Subdirectories are pushed only while a batch is
        /// held, so an empty queue with none of them means everything
        /// discovered has been visited: the walk is over, not waiting.
        var working = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many directories one worker takes per lock acquisition. Batching
    /// keeps the lock traffic next to the enumerations rather than per
    /// directory.
    private static let batchSize = 64

    init(root: String) {
        state.withLock { $0.pending = [root] }
    }

    /// The next batch of directories, or nil when the walk is over.
    func nextBatch() async -> [String]? {
        while true {
            let outcome = state.withLock { state -> Outcome? in
                guard !state.pending.isEmpty else {
                    return state.working == 0 ? .done : nil
                }
                let size = min(Self.batchSize, state.pending.count)
                let batch = Array(state.pending.suffix(size))
                state.pending.removeLast(size)
                state.working += 1
                return .batch(batch)
            }
            switch outcome {
            case .batch(let batch):
                return batch
            case .done:
                return nil
            case nil:
                if Task.isCancelled { return nil }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    func push(contentsOf paths: [String]) {
        guard !paths.isEmpty else { return }
        state.withLock { $0.pending.append(contentsOf: paths) }
    }

    /// Hands a finished batch back. Taking the worker off `working` here —
    /// after its subdirectories are already in the queue — is what makes the
    /// empty-queue check above sound.
    func record() {
        state.withLock { $0.working -= 1 }
    }

    private enum Outcome {
        case batch([String])
        case done
    }
}

/// Throttles progress events and totals the hits.
///
/// A lock rather than an actor, the same choice and for the same reason as
/// the disk analysis's gate: the tick runs once per directory, and an actor
/// hop costs a suspension plus a resume for what is two integers — on a
/// 150 k-directory walk that is 150 k task switches on a counter. The state
/// is never held across a suspension, so an unfair lock is enough: every
/// stored property is a `let` of a `Sendable` type and the mutable state
/// lives inside the lock, which is what makes this class `Sendable` without
/// an exemption.
private final class LargeFileProgressGate: Sendable {
    private struct State {
        var scanned = 0
        var found = 0
        var foundBytes: Int64 = 0
        var unreadable = 0
        var lastYield: ContinuousClock.Instant?
    }

    private let continuation: AsyncStream<LargeFileScanEvent>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let interval: Duration = .milliseconds(120)

    init(_ continuation: AsyncStream<LargeFileScanEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Records one enumerated directory and publishes progress at most once
    /// per interval. Hundreds of thousands of directories would otherwise
    /// wake the main actor thousands of times a second for a label that
    /// changes too fast to read.
    func tick(_ path: String) {
        // The decision is made under the lock and the event handed over
        // outside it: yielding to the consumer is not something the other
        // workers should wait behind. The lock body returns what to publish
        // rather than writing to a captured variable — it runs on whichever
        // worker took the lock, so it may not touch the caller's stack.
        let pending: (scanned: Int, current: String)? = state.withLock { state in
            state.scanned += 1
            let now = ContinuousClock.now
            if let lastYield = state.lastYield, now - lastYield < interval { return nil }
            state.lastYield = now
            return (state.scanned, path)
        }
        if let pending {
            continuation.yield(.progress(scanned: pending.scanned, current: pending.current))
        }
    }

    /// Records and publishes one hit. Not throttled: a walk finds tens of
    /// these, and each is a finished fact the user can read while the walk
    /// continues.
    func found(_ file: LargeFile) {
        state.withLock { state in
            state.found += 1
            state.foundBytes += file.size
        }
        continuation.yield(.found(file))
    }

    func unreadable() {
        state.withLock { $0.unreadable += 1 }
    }

    var foundCount: Int { state.withLock { $0.found } }
    var foundBytes: Int64 { state.withLock { $0.foundBytes } }
    var unreadableCount: Int { state.withLock { $0.unreadable } }
}
