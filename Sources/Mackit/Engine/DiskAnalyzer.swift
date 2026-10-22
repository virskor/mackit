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

    /// Size descending, name ascending on ties: the order every level of the
    /// tree is published in. Shared rather than inlined at each sort site so a
    /// subtree grafted over a placeholder is re-ordered by the rule the scan
    /// itself used — a promoted folder can outgrow the sibling it is listed
    /// behind, and a second copy of this comparator would drift from it.
    static func bySizeDescending(_ lhs: DiskEntry, _ rhs: DiskEntry) -> Bool {
        lhs.size == rhs.size ? lhs.name < rhs.name : lhs.size > rhs.size
    }
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
    ///
    /// The traversal is a fixed pool of workers over one shared queue of
    /// directories, not a task per directory. A task per directory looks
    /// natural — each subtree is its own little computation — but the
    /// population is not bounded by the concurrency limit: a parent task stays
    /// alive waiting for its children however deep the tree runs, so the
    /// semaphore that caps concurrent *enumerations* caps nothing about how
    /// many tasks exist at once. Measured on a real startup disk (1.7 M
    /// directories) that peaked at 871 k live tasks and 2.7 GB resident, all
    /// of it suspended parents and children queued behind the semaphore. Here
    /// the only tasks are the workers; the tree itself is data — paths in the
    /// queue, one small aggregation object per directory from the moment its
    /// job starts until its subtree finishes — so the footprint no longer
    /// grows with the tree.
    static func scan(
        root: String,
        protectedPaths: Set<String>,
        maxDepth: Int = DiskAnalyzer.maxDepth
    ) -> AsyncStream<DiskScanEvent> {
        AsyncStream(DiskScanEvent.self) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startedAt = ContinuousClock.now
                let progress = ProgressGate(continuation)
                let queue = MeasureQueue()
                queue.push(MeasureJob(path: root, budget: maxDepth, parent: nil))
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<ScanEngine.maxConcurrentMeasurements {
                        group.addTask {
                            await measureThroughQueue(
                                queue: queue,
                                protectedPaths: protectedPaths,
                                progress: progress
                            )
                        }
                    }
                }
                // The group ends when the root's subtree has been finalized
                // (the walk is over) or the scan was cancelled. A cancelled
                // scan publishes nothing: its partial tree would be presented
                // as a finished one.
                if !Task.isCancelled, let node = queue.finishedEntry {
                    let scanned = progress.scannedCount
                    continuation.yield(.finished(node, directories: scanned))
                    MackitLog.disk.info(
                        "analyzed \(root, privacy: .public): \(scanned, privacy: .public) directories, \(node.size, privacy: .public) bytes, took \(MackitLog.duration(.now - startedAt), privacy: .public)"
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One worker of the measurement pool: takes batches of directories off
    /// the shared queue until the whole tree has been measured.
    ///
    /// An empty queue is not the end of the walk — another worker may be
    /// mid-enumeration with subdirectories still to push — so a worker that
    /// finds nothing polls briefly instead of exiting. It exits for good when
    /// the root's subtree has been finalized (`done`) or the scan was
    /// cancelled. Polling rather than parking on a continuation keeps a
    /// cancelled worker waking up, the same choice the counting pass makes.
    private static func measureThroughQueue(
        queue: MeasureQueue,
        protectedPaths: Set<String>,
        progress: ProgressGate
    ) async {
        while !Task.isCancelled {
            guard let batch = queue.nextBatch() else {
                if queue.isDone { return }
                try? await Task.sleep(for: .milliseconds(1))
                continue
            }
            for job in batch {
                if queue.isDone || Task.isCancelled { return }
                await measure(job, queue: queue, protectedPaths: protectedPaths, progress: progress)
            }
        }
    }

    /// Measures one directory: enumerates it, sums its files, and hands its
    /// subdirectories to the queue as jobs of their own.
    ///
    /// A directory that cannot be read at all (a denied TCC prompt, a locked
    /// folder, or one that vanished mid-scan) enumerates as nothing. It is
    /// flagged rather than reported as an empty folder — or "0 B" — for a
    /// real one.
    private static func measure(
        _ job: MeasureJob,
        queue: MeasureQueue,
        protectedPaths: Set<String>,
        progress: ProgressGate
    ) async {
        let node = MeasureNode(path: job.path, budget: job.budget, parent: job.parent)
        let entries = FileSystem.entries(of: job.path)
        progress.tick(job.path)

        // The lock body returns whether this was the node's last unit of work
        // rather than writing to a captured variable: it may run on whichever
        // worker took the lock, so it may not touch the caller's stack.
        let ready = node.state.withLock { state -> Bool in
            if let entries {
                let retain = job.budget > 0
                var children: [DiskEntry] = []
                var subdirectories: [MeasureJob] = []
                for entry in entries {
                    if systemMarkers.contains(entry.name) { continue }
                    if entry.isSymbolicLink { continue }
                    if entry.isDirectory {
                        // A mount point is another volume: not listed, not
                        // counted, not entered (see the type comment).
                        if entry.isMountPoint { continue }
                        state.folderCount += 1
                        // `entry.path` is computed on demand: a file the
                        // budget does not retain (the deep majority of a
                        // whole-disk tree) never pays for a path it does not
                        // need.
                        if protectedPaths.contains(entry.path) {
                            if retain {
                                children.append(
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
                        subdirectories.append(
                            MeasureJob(path: entry.path, budget: job.budget - 1, parent: node)
                        )
                    } else {
                        state.fileCount += 1
                        state.total += entry.allocatedSize
                        if retain {
                            children.append(
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
                state.children = children
                // The count is raised before the jobs become visible to other
                // workers: a subdirectory that runs and finishes at once would
                // otherwise fold into this node before the work it represents
                // was ever counted, finalizing it early with a partial total.
                state.pending += subdirectories.count
                queue.push(contentsOf: subdirectories)
            } else {
                state.unreadable = true
            }
            // This directory's own enumeration is the last unit of its work.
            state.pending -= 1
            return state.pending == 0
        }

        if ready {
            fold(finalize(node), from: node, into: queue)
        }
    }

    /// Builds a finished node's entry. Called once the node is exclusively
    /// this worker's — its pending count reached zero, so no child will
    /// report into it again.
    private static func finalize(_ node: MeasureNode) -> DiskEntry {
        let snapshot = node.state.withLock { $0 }
        // Size descending, name ascending on ties: the largest child first is
        // both what the list shows and what the treemap needs, and a stable
        // tiebreak keeps the order deterministic.
        var children = node.retain ? snapshot.children : []
        children.sort(by: DiskEntry.bySizeDescending)
        return DiskEntry(
            path: node.path,
            name: node.name,
            isDirectory: true,
            size: snapshot.total,
            folderCount: snapshot.folderCount,
            fileCount: snapshot.fileCount,
            children: children,
            isUnreadable: snapshot.unreadable,
            isSkipped: false,
            isTruncated: !node.retain
        )
    }

    /// Folds a finished subtree into its parent, then finalizes every
    /// ancestor whose last child just landed. Runs on whichever worker
    /// finished the subtree; the walk up is one step per level of depth and
    /// never holds a lock while taking the next, so it cannot deadlock.
    private static func fold(_ entry: DiskEntry, from node: MeasureNode, into queue: MeasureQueue) {
        var current = entry
        var currentNode = node
        while true {
            guard let parent = currentNode.parent else {
                // The root's subtree is the whole tree: the walk is over.
                queue.finish(with: current)
                return
            }
            // The lock body returns the parent when its last child just
            // landed, and may not touch the caller's variables — it runs on
            // whichever worker took the lock.
            let folded = current
            let finished: MeasureNode? = parent.state.withLock { state in
                state.total += folded.size
                if parent.retain { state.children.append(folded) }
                state.pending -= 1
                return state.pending == 0 ? parent : nil
            }
            guard let parentDone = finished else { return }
            current = finalize(parentDone)
            currentNode = parentDone
        }
    }
}

/// One directory waiting to be measured: its path, how many levels of
/// children to retain below it, and the node its result folds into.
private struct MeasureJob: Sendable {
    let path: String
    let budget: Int
    let parent: MeasureNode?
}

/// One directory being measured: the aggregation state its children report
/// into, plus the link up to its parent.
///
/// The mutable state lives inside an unfair lock, which is what makes this
/// class `Sendable` without an exemption: every stored property is a `let` of
/// a `Sendable` type, and the lock is held only to merge a result — never
/// across the enumeration that produces one.
private final class MeasureNode: Sendable {
    struct State {
        /// Recursive allocated size so far: this directory's own files plus
        /// every subdirectory that has folded in.
        var total: Int64 = 0
        var folderCount = 0
        var fileCount = 0
        /// Units of work still outstanding: this directory's own enumeration
        /// plus one per subdirectory job handed to the queue. Zero means every
        /// child has folded in and the node can be finalized.
        var pending = 1
        /// Retained children, in enumeration order; sorted on finalize.
        var children: [DiskEntry] = []
        var unreadable = false
    }

    let path: String
    let name: String
    /// Whether this node keeps its children's nodes. A node past the depth
    /// budget is still measured — enumerated, and its directories still
    /// traversed for their sizes — it just does not retain, which is what
    /// `isTruncated` reports.
    let retain: Bool
    let parent: MeasureNode?
    let state = OSAllocatedUnfairLock(initialState: State())

    init(path: String, budget: Int, parent: MeasureNode?) {
        self.path = path
        self.name = FileSystem.lastComponent(of: path)
        self.retain = budget > 0
        self.parent = parent
    }
}

/// The measurement's shared work queue.
///
/// Jobs are taken from the back — depth first — because a depth-first walk
/// finishes one subtree before starting the next, which keeps the set of
/// nodes being aggregated, and with it the queue's own depth, as narrow as
/// the tree allows.
///
/// The walk is over when the root's subtree has been finalized, which is a
/// fact this queue records. A drained queue cannot tell a worker that on its
/// own — another worker may be mid-enumeration with children still to push —
/// so an idle worker polls rather than exiting (see
/// `measureThroughQueue`).
private final class MeasureQueue: Sendable {
    private struct State {
        var jobs: [MeasureJob] = []
        var done = false
        var finished: DiskEntry?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many jobs one worker takes per lock acquisition. Batching keeps
    /// the lock traffic next to the enumerations rather than per directory.
    private static let batchSize = 64

    func push(_ job: MeasureJob) {
        state.withLock { $0.jobs.append(job) }
    }

    func push(contentsOf jobs: [MeasureJob]) {
        guard !jobs.isEmpty else { return }
        state.withLock { state in
            state.jobs.append(contentsOf: jobs)
        }
    }

    func nextBatch() -> [MeasureJob]? {
        state.withLock { state in
            guard !state.jobs.isEmpty else { return nil }
            let size = min(Self.batchSize, state.jobs.count)
            let batch = Array(state.jobs.suffix(size))
            state.jobs.removeLast(size)
            return batch
        }
    }

    var isDone: Bool {
        state.withLock { $0.done }
    }

    var finishedEntry: DiskEntry? {
        state.withLock { $0.finished }
    }

    /// Records the root's finished subtree and ends the walk.
    func finish(with entry: DiskEntry) {
        state.withLock { state in
            state.done = true
            state.finished = entry
        }
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
