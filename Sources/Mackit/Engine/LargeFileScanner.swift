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

    /// Display text of the size, computed once here rather than per row per
    /// frame — the same trade `JunkItem` makes, for the same reason: a
    /// whole-disk walk lists hundreds of files, and every scroll frame used
    /// to re-run `ByteCountFormatStyle` for each visible one.
    private(set) var sizeText: String

    init(path: String, name: String, size: Int64, modified: Date?, parentPath: String) {
        self.path = path
        self.name = name
        self.size = size
        self.modified = modified
        self.parentPath = parentPath
        self.sizeText = Formatters.bytes(size)
    }

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
/// - the Trash is never entered: its contents are already marked for removal,
///   and the clean engine deletes in-Trash items outright, so offering one
///   would put a permanent delete behind the confirmation sheet's
///   move-to-Trash wording;
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
    /// Walk `root`, reporting every regular file at or above `threshold`
    /// bytes. Cancelling the stream's consumer cancels the underlying walk.
    ///
    /// `protectedPaths` are the folders this walk refuses to enter without an
    /// explicit request (the TCC-protected home trio by default): the caller
    /// passes its session's set, the same contract the disk analysis scan
    /// has — a stale default would silently re-skip (or re-enter) folders the
    /// user already decided about.
    ///
    /// `trashDirectory` stands in for the system Trash in tests: a fixture
    /// cannot be the real one, so a test passes its own and the walk
    /// excludes that — the same seam `CleanEngine.removeFromDisk` uses.
    /// Nil (the default) resolves the real Trash from `root`'s volume.
    static func scan(
        root: String,
        protectedPaths: Set<String>,
        threshold: Int64,
        trashDirectory: URL? = nil
    ) -> AsyncStream<LargeFileScanEvent> {
        AsyncStream(LargeFileScanEvent.self) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startedAt = ContinuousClock.now
                let progress = LargeFileProgressGate(continuation)
                let queue = ScanWalkQueue(root: root)
                // Resolved once rather than per directory: the walk never
                // crosses volumes (mount points are skipped), so the root's
                // own Trash is the only one it can reach. Standardized to
                // match the spelling the walk's joined paths produce.
                let trashPath = (trashDirectory ?? FileSystem.trashDirectory(forDirectory: URL(fileURLWithPath: root)))?
                    .standardizedFileURL.path
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<ScanEngine.maxConcurrentMeasurements {
                        group.addTask {
                            await walkThroughQueue(
                                queue: queue,
                                protectedPaths: protectedPaths,
                                threshold: threshold,
                                trashPath: trashPath,
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
        queue: ScanWalkQueue,
        protectedPaths: Set<String>,
        threshold: Int64,
        trashPath: String?,
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
                walk(path, protectedPaths: protectedPaths, threshold: threshold, trashPath: trashPath, progress: progress, into: &subdirectories)
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
        trashPath: String?,
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
            if FileSystem.volumeMarkers.contains(entry.name) { continue }
            // A symlinked child is neither followed nor listed: not followed
            // avoids double-counting the target and cycles; not listed keeps
            // the link's own few dozen bytes from ever passing the threshold.
            if entry.isSymbolicLink { continue }
            if entry.isDirectory {
                // A mount point is another volume: not listed, not counted,
                // not entered (see the type comment).
                if entry.isMountPoint { continue }
                if protectedPaths.contains(entry.path) { continue }
                // The Trash is the system's staging area for removal: its
                // contents are already marked for deletion and the clean
                // engine deletes in-Trash items outright, so a file sitting
                // there must never be offered — the sheet would say "moved
                // to Trash" over a permanent delete. The helper also covers
                // the per-volume `.Trashes` container, not just the user's
                // own Trash.
                if FileSystem.isTrashDirectory(entry.path, resolvingTo: trashPath) { continue }
                subdirectories.append(entry.path)
            } else if entry.isRegularFile, entry.allocatedSize >= threshold {
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
