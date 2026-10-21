import Foundation
import os

/// One node of the disk analysis tree: a directory or file with its recursive
/// allocated size, and — for directories — the children the scan retained.
///
/// `id` is the path — unique within a tree and stable across rescans, so the
/// list selection and the treemap layout can key on it. Paths are spelled the
/// way the traversal's base URL was (a firmlinked `/Users` stays `/Users`, it
/// is not resolved to the data volume), which is why the protected-path sets
/// carry both spellings.
struct DiskEntry: Identifiable, Sendable {
    let path: String
    /// Display name. A `var` because the model renames the scan's root to the
    /// volume's own name once the tree lands.
    var name: String
    let isDirectory: Bool

    /// Recursive allocated size in bytes — everything below this entry,
    /// including the levels the scan did not retain.
    var size: Int64
    /// Direct children split into folders and files: what the header's
    /// "N folders M files" line shows. Known even when `children` is empty —
    /// the level where the depth budget ran out is still enumerated, only its
    /// nodes are not kept.
    var folderCount: Int
    var fileCount: Int
    /// Direct children, size descending (name ascending on ties). Empty for
    /// files, for folders the scan did not retain (`isTruncated`), and for
    /// unreadable ones.
    var children: [DiskEntry]

    /// The folder exists but the process may not read it (a denied TCC
    /// prompt, or a permission-locked directory). Such a folder enumerates as
    /// empty, so without this flag its row would claim "0 B".
    var isUnreadable: Bool
    /// A TCC-protected home folder (Documents / Desktop / Downloads): listed
    /// but deliberately not measured, because measuring it pops the system
    /// access dialog. The user can scan one explicitly — see
    /// `DiskAnalysisModel.scanFolder`.
    var isSkipped: Bool
    /// Measured, but its children were not retained: the scan's depth budget
    /// ran out here. The size and counts are real; entering the folder scans
    /// it the same way the whole disk was scanned.
    var isTruncated: Bool

    var id: String { path }

    /// Total direct child count: what the left list's "N items" line shows.
    var itemCount: Int { folderCount + fileCount }
}

/// Events while analyzing a directory tree.
enum DiskScanEvent: Sendable {
    /// One more directory enumerated: the running count and the directory
    /// just visited, for the scanning screen. Throttled inside the analyzer.
    case progress(scanned: Int, current: String)
    /// The whole tree is measured. This is the only event that carries
    /// results: the page shows its scanning screen until this arrives and
    /// never a half-filled list, because numbers that are still moving invite
    /// the user to read them. `directories` is the final directory count —
    /// the progress events are throttled, so the last one can lag behind the
    /// real total, and the caller needs the exact number to remember it as
    /// the next scan's denominator.
    case finished(DiskEntry, directories: Int)
}

/// Read-only disk space analysis: measure one directory tree in a single pass
/// and hand the whole tree back when it is done.
///
/// Deliberately one whole-tree scan rather than per-directory measurements
/// streamed in as they land. The tool answers "where did the space go" across
/// the whole disk — including `Users › … › Library › Containers`, where the
/// reclaimable container junk lives — and a traversal that visits every byte
/// anyway might as well build the tree once, so that drilling down is instant
/// instead of a wait per level.
///
/// Safety rules inherited from the cleaning engine's enumeration:
/// - `com.apple.*` children are skipped (TCC-protected on macOS 26+;
///   enumerating them pops an authorization dialog) — `FileSystem.entries`
///   already applies this;
/// - the volume-root plumbing (`.nofollow` and friends) is skipped by name at
///   any depth: on macOS 26+ `.nofollow` mirrors the whole volume root, so
///   traversing it counts every byte on the disk a second time. They are
///   filesystem plumbing, never user content;
/// - symlinked children are skipped: not followed (avoids double-counting
///   `/var` against `/private/var` and avoids cycles) and not counted — the
///   firmlinks the traversal *does* follow (`/Users`, `/Library`) are not
///   symlinks, so user data is still reached exactly once;
/// - mount points are skipped entirely: a startup-disk scan reaches the data
///   volume's contents through the firmlinks, and listing the mount point as
///   well would show a near-empty row for a volume that holds half the disk;
/// - unreadable directories are flagged rather than probed;
/// - the TCC-protected home trio is listed as skipped and left unmeasured, so
///   no access dialog fires mid-scan.
enum DiskAnalyzer {
    /// How many levels of children a scan retains below its root.
    ///
    /// The traversal itself is unbounded — every byte has to be visited to
    /// measure a size — but the *retained* nodes are what cost memory, and
    /// their count explodes with depth: measured on a real ~500 GB volume,
    /// six levels retain ~220 k nodes (about 45 MB), seven levels ~490 k, and
    /// eight over a million, almost all of them `node_modules` and container
    /// internals. Six keeps the tool's footprint bounded while covering
    /// `Users › … › Library › Containers` and its children; deeper levels are
    /// one explicit scan away (see `DiskEntry.isTruncated`).
    static let maxDepth = 6

    /// Volume-root plumbing that must not be listed or traversed: the
    /// firmlink marker dirs (macOS 26+) and the permission-less `.file`
    /// placeholder. Skipped by name at any depth — they only ever exist at
    /// volume roots and inside `.nofollow`'s mirror of one.
    private static let systemMarkers: Set<String> = [".nofollow", ".resolve", ".vol", ".file"]

    /// Counts the directories a scan of `root` will visit, applying the same
    /// skip rules, so the scan can publish a real fraction and a remaining
    /// time instead of sweeping until the tree has been measured once.
    ///
    /// Enumerated with `FileSystem.directories(of:)` rather than the
    /// measurement's own `entries(of:)`: the bulk attribute call reads every
    /// entry's attributes — the work that makes measuring expensive — so
    /// counting through it would land no earlier than the measurement it
    /// follows, while a readdir walk needs only names and types. That walk still
    /// costs roughly what the measurement does (2.9 s against 2.7 s on a real
    /// 150 k-directory tree), which is why it runs alongside rather than before,
    /// and why the result is remembered per tree.
    ///
    /// Parallel through a shared queue rather than a fixed split: on a real
    /// startup disk one child of the root (`/Users`) holds over three quarters
    /// of the tree, so dealing the root's children out once left every other
    /// worker idle and the count no faster than a single walker. Workers hand
    /// back the surplus of their own stacks instead, so an idle worker always
    /// has something to take.
    ///
    /// Runs concurrently with the measurement rather than before it, and is
    /// remembered per tree (see `ScanProgressHistory`), so it runs once per
    /// tree and skip set rather than once per scan.
    static func countDirectories(root: String, protectedPaths: Set<String>) async -> Int {
        // The walk blocks on readdir, so it runs detached rather than on the
        // caller's actor — the main actor must stay free for the scanning
        // screen. A detached task carries its own cancellation flag, which
        // cancelling the caller would not reach, hence the handler that
        // cancels the walk itself; the walk checks that flag between
        // directories, so stopping a scan stops the count too.
        let walk = Task.detached(priority: .userInitiated) {
            await countThroughQueue(root: root, protectedPaths: protectedPaths)
        }
        return await withTaskCancellationHandler {
            await walk.value
        } onCancel: {
            walk.cancel()
        }
    }

    /// Drives the queue with one worker per available concurrency slot.
    private static func countThroughQueue(root: String, protectedPaths: Set<String>) async -> Int {
        let queue = DirectoryWalkQueue(root: root)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<ScanEngine.maxConcurrentMeasurements {
                group.addTask {
                    while let batch = await queue.nextBatch() {
                        let result = await countBatch(batch, protectedPaths: protectedPaths, queue: queue)
                        await queue.record(counted: result.counted, shed: result.shed)
                    }
                }
            }
        }
        return await queue.counted
    }

    /// Walks a batch of directories depth-first, counting them and handing the
    /// surplus of its own stack back to the queue once that stack grows — an
    /// idle worker picks it up, which is what keeps the walk parallel when one
    /// subtree dwarfs all the others. Returns the directories this worker
    /// counted plus the ones it shed for others.
    private static func countBatch(
        _ batch: [String],
        protectedPaths: Set<String>,
        queue: DirectoryWalkQueue
    ) async -> (counted: Int, shed: [String]) {
        var stack = batch
        var counted = 0
        var shed: [String] = []
        while let path = stack.popLast() {
            if Task.isCancelled { break }
            counted += 1
            guard let children = FileSystem.directories(of: path) else { continue }
            for child in children {
                if systemMarkers.contains(FileSystem.lastComponent(of: child)) { continue }
                if protectedPaths.contains(child) { continue }
                stack.append(child)
            }
            if stack.count >= Self.shareThreshold {
                let surplus = Array(stack.suffix(stack.count / 2))
                stack.removeLast(surplus.count)
                shed.append(contentsOf: surplus)
            }
        }
        return (counted, shed)
    }

    /// How deep a worker's own stack grows before it hands half of it back.
    /// Small enough that an idle worker is never left waiting long, large
    /// enough that the hand-backs stay rare next to the readdirs.
    private static let shareThreshold = 256

    /// The counting pass's shared work queue.
    ///
    /// Workers take batches, walk them depth-first, and hand back the surplus
    /// of their stacks; a worker that runs dry polls briefly rather than
    /// exiting, because another may still hand work back. Polling instead of
    /// parking on a continuation keeps a cancelled worker waking up.
    private actor DirectoryWalkQueue {
        private var pending: [String]
        /// Workers holding a batch right now — between taking one and handing
        /// its result back. Results are recorded inside the actor, so an empty
        /// queue with none of them means everything discovered has been
        /// counted: the walk is over, not waiting.
        private var working = 0
        private var total = 0

        init(root: String) {
            self.pending = [root]
        }

        /// The next batch of directories, or nil when the walk is over.
        func nextBatch() async -> [String]? {
            while true {
                if let batch = takeBatch() {
                    working += 1
                    return batch
                }
                if working == 0 { return nil }
                if Task.isCancelled { return nil }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }

        /// What a worker counted and what it shed for the others. Taking the
        /// worker off `working` here — rather than when it asks for more — is
        /// what makes the empty-queue check above sound: anything it found is
        /// already in the queue by the time it stops counting as busy.
        func record(counted: Int, shed: [String]) {
            working -= 1
            total += counted
            pending.append(contentsOf: shed)
        }

        var counted: Int { total }

        private func takeBatch() -> [String]? {
            guard !pending.isEmpty else { return nil }
            let size = min(Self.batchSize, pending.count)
            let batch = Array(pending.suffix(size))
            pending.removeLast(size)
            return batch
        }

        private static let batchSize = 64
    }

    /// Analyze one directory tree. Cancelling the stream's consumer cancels
    /// the underlying measurement task.
    ///
    /// `protectedPaths` are the folders this scan refuses to enter without an
    /// explicit request (the TCC-protected home trio by default): they are
    /// listed as skipped rows and left unmeasured, so no access dialog fires
    /// mid-scan. Passed explicitly rather than defaulted: the caller's set
    /// carries its session's approvals, and a stale default would silently
    /// re-skip (or re-enter) folders the user already decided about.
    static func scan(
        root: String,
        protectedPaths: Set<String>,
        maxDepth: Int = DiskAnalyzer.maxDepth
    ) -> AsyncStream<DiskScanEvent> {
        AsyncStream(DiskScanEvent.self) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startedAt = ContinuousClock.now
                let progress = ProgressGate(continuation)
                let semaphore = AsyncSemaphore(max: ScanEngine.maxConcurrentMeasurements)
                if let node = await scanDirectory(
                    path: root,
                    budget: maxDepth,
                    protectedPaths: protectedPaths,
                    semaphore: semaphore,
                    progress: progress
                ) {
                    let scanned = progress.scannedCount
                    continuation.yield(.finished(node, directories: scanned))
                    MackitLog.disk.info(
                        "analyzed \(root, privacy: .public): \(scanned, privacy: .public) directories, \(node.size, privacy: .public) bytes, took \(MackitLog.duration(.now - startedAt), privacy: .public)"
                    )
                }
                // A cancelled scan publishes nothing: its partial tree would
                // be presented as a finished one.
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Measures the subtree at `path`. Returns nil only when the task was
    /// cancelled mid-scan.
    ///
    /// `budget` is how many more levels of children to retain; zero (or
    /// negative) means "measure only" — the level is still enumerated and its
    /// directories still traversed for their sizes, but no nodes are kept.
    private static func scanDirectory(
        path: String,
        budget: Int,
        protectedPaths: Set<String>,
        semaphore: AsyncSemaphore,
        progress: ProgressGate
    ) async -> DiskEntry? {
        if Task.isCancelled { return nil }
        let name = FileSystem.lastComponent(of: path)
        // The semaphore gates only the enumeration, never the recursion: a
        // permit held across a child task would deadlock the moment every
        // permit sat on an ancestor waiting for a descendant.
        let entries = await semaphore.withPermit { FileSystem.entries(of: path) }
        progress.tick(path)
        // An unreadable directory (a denied TCC prompt, a locked folder, or
        // one that vanished mid-scan) enumerates as nothing. Flag it rather
        // than reporting an empty folder — or "0 B" — for a real one.
        guard let entries else {
            return DiskEntry(
                path: path,
                name: name,
                isDirectory: true,
                size: 0,
                folderCount: 0,
                fileCount: 0,
                children: [],
                isUnreadable: true,
                isSkipped: false,
                isTruncated: false
            )
        }

        let retain = budget > 0
        var total: Int64 = 0
        var folderCount = 0
        var fileCount = 0
        var nodes: [DiskEntry] = []
        var directories: [String] = []

        for entry in entries {
            if systemMarkers.contains(entry.name) { continue }
            if entry.isSymbolicLink { continue }
            if entry.isDirectory {
                // A mount point is another volume: not listed, not counted,
                // not entered (see the type comment).
                if entry.isMountPoint { continue }
                folderCount += 1
                // `entry.path` is computed on demand: a file the budget does
                // not retain (the deep majority of a whole-disk tree) never
                // pays for a path it does not need.
                if protectedPaths.contains(entry.path) {
                    if retain {
                        nodes.append(
                            DiskEntry(
                                path: entry.path,
                                name: entry.name,
                                isDirectory: true,
                                size: 0,
                                folderCount: 0,
                                fileCount: 0,
                                children: [],
                                isUnreadable: false,
                                isSkipped: true,
                                isTruncated: false
                            )
                        )
                    }
                    continue
                }
                directories.append(entry.path)
            } else {
                fileCount += 1
                total += entry.allocatedSize
                if retain {
                    nodes.append(
                        DiskEntry(
                            path: entry.path,
                            name: entry.name,
                            isDirectory: false,
                            size: entry.allocatedSize,
                            folderCount: 0,
                            fileCount: 0,
                            children: [],
                            isUnreadable: false,
                            isSkipped: false,
                            isTruncated: false
                        )
                    )
                }
            }
        }

        // Directories are scanned in chunks: a single directory can hold
        // hundreds of thousands of subdirectories, and spawning a task per
        // child at once would park that many suspended tasks on the
        // semaphore. Each chunk still runs fully concurrently.
        let chunkSize = 64
        var index = 0
        while index < directories.count {
            if Task.isCancelled { return nil }
            let end = min(index + chunkSize, directories.count)
            await withTaskGroup(of: DiskEntry?.self) { group in
                for position in index..<end {
                    let childPath = directories[position]
                    group.addTask {
                        await scanDirectory(
                            path: childPath,
                            budget: budget - 1,
                            protectedPaths: protectedPaths,
                            semaphore: semaphore,
                            progress: progress
                        )
                    }
                }
                for await node in group {
                    guard let node else { continue }
                    total += node.size
                    if retain { nodes.append(node) }
                }
            }
            index = end
        }

        if retain {
            // Size descending, name ascending on ties: the largest child
            // first is both what the list shows and what the treemap needs,
            // and a stable tiebreak keeps the order deterministic.
            nodes.sort { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
        }

        return DiskEntry(
            path: path,
            name: name,
            isDirectory: true,
            size: total,
            folderCount: folderCount,
            fileCount: fileCount,
            children: retain ? nodes : [],
            isUnreadable: false,
            isSkipped: false,
            isTruncated: !retain
        )
    }
}

/// Throttles progress events.
///
/// The traversal enumerates hundreds of thousands of directories, and one
/// event per directory would wake the main actor thousands of times a second
/// for a label that changes too fast to read.
///
/// A lock rather than an actor: the tick runs once per directory, and an actor
/// hop costs a suspension plus a resume for what is two integers — one per
/// directory, so on a 150 k-directory tree the actor version spent 150 k task
/// switches on a counter. The state is two fields and is never held across a
/// suspension, so an unfair lock is enough: every stored property is a `let` of
/// a `Sendable` type and the mutable state lives inside the lock, which is what
/// makes this class `Sendable` without an exemption.
private final class ProgressGate: Sendable {
    private struct State {
        var scanned = 0
        var lastYield: ContinuousClock.Instant?
    }

    private let continuation: AsyncStream<DiskScanEvent>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    private let interval: Duration = .milliseconds(120)

    init(_ continuation: AsyncStream<DiskScanEvent>.Continuation) {
        self.continuation = continuation
    }

    func tick(_ path: String) {
        // The decision is made under the lock and the event is handed over
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

    /// Directories measured so far, for the completion log.
    var scannedCount: Int { state.withLock { $0.scanned } }
}
