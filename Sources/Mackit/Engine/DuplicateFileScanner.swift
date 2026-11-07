import Foundation
import CryptoKit
import os

/// One file inside a duplicate group.
///
/// `size` is the kernel's allocated size for the file — the same figure the
/// large-file walk reports, so rows and reclaim estimates read the same way
/// across tools. The grouping key itself is the file's *logical* size, which
/// the walk reads from the bulk enumeration and the probe re-checks with
/// lstat: two copies of the same content always share the logical size, while
/// allocation can drift apart (sparse regions, compression) and must not
/// split identical files into different buckets.
struct DuplicateFile: Identifiable, Sendable, Hashable {
    let path: String
    let name: String
    /// Bytes allocated to the file, as the kernel reports them.
    let size: Int64
    /// Content size shared by every member of the group. The header prints
    /// this rather than the allocation, which can differ between a sparse
    /// copy and a dense one.
    let logicalSize: Int64
    /// Last modification date, or nil when the filesystem would not say.
    let modified: Date?
    /// The directory holding the file, spelled as the traversal spelled it.
    let parentPath: String
    /// The vnode identity at hash time. The clean engine re-reads it right
    /// before the mutation and refuses a path that now names a different
    /// file — a duplicate listed minutes ago must not be deleted under
    /// whatever replaced it (see `CleanEngine.remove`).
    let nodeIdentity: FileSystem.NodeIdentity?

    /// Display text of the size, computed once rather than per row per frame
    /// — the same trade `JunkItem` and `LargeFile` make.
    private(set) var sizeText: String

    init(
        path: String,
        name: String,
        size: Int64,
        logicalSize: Int64? = nil,
        modified: Date?,
        parentPath: String,
        nodeIdentity: FileSystem.NodeIdentity?
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.logicalSize = logicalSize ?? size
        self.modified = modified
        self.parentPath = parentPath
        self.nodeIdentity = nodeIdentity
        self.sizeText = Formatters.bytes(size)
    }

    var id: String { path }
}

/// A group of files with byte-identical content. `files` always holds at
/// least two entries; which copy to keep is a presentation decision and is
/// deliberately left to the model.
struct DuplicateGroup: Identifiable, Sendable, Hashable {
    /// Stable within a scan: the shared logical size and the content digest,
    /// which cannot collide across groups of one scan.
    let id: String
    let files: [DuplicateFile]

    /// The bytes the redundant copies are allocated. With equal allocations
    /// — the common case — this is exact. A group can also hold copies whose
    /// allocations differ (a sparse copy of a dense file), so the largest
    /// copy is treated as the one kept and the rest are summed: a
    /// reclaimable figure must not promise bytes that trashing the copies
    /// would not actually free. This is still an allocation-based estimate —
    /// APFS clones share blocks physically, so deleting one clone can return
    /// less — and the clean result card reports what each removal actually
    /// measured.
    var wasted: Int64 {
        guard files.count > 1, let largest = files.map(\.size).max() else { return 0 }
        return files.reduce(0) { $0 + $1.size } - largest
    }
}

/// Events while searching for duplicate files.
enum DuplicateFileScanEvent: Sendable {
    /// One more directory enumerated: the running count and the directory
    /// just visited. Throttled inside the scanner.
    case progress(scanned: Int, current: String)
    /// Content comparison is running: bytes hashed so far, the total that
    /// still has to be read, and the file being read. Throttled.
    case hashing(compared: Int64, total: Int64, current: String)
    /// A finished group of identical files. Emitted the moment comparison
    /// proves it, not held for the end of the scan.
    case found(DuplicateGroup)
    /// The scan is over. `unreadableDirectories` counts the folders the
    /// process could not read at all — without Full Disk Access those hold
    /// files the scan never saw. `skippedLinkedFiles` counts candidates that
    /// were excluded for having several names (hard links): deleting one
    /// name of such a file frees nothing, so it is never offered as a
    /// reclaimable duplicate.
    case finished(unreadableDirectories: Int, skippedLinkedFiles: Int)
}

/// Read-only search for duplicate files under one directory tree.
///
/// The pipeline runs in three passes, each one a cheap filter over the
/// previous: the walk retains only files at or above the threshold and
/// buckets them by logical size (the size is already in the bulk enumeration
/// record, so this pass costs nothing extra); the hash stage stats the
/// candidates of multi-file buckets (skipping multi-link files, whose
/// deletion frees nothing, and files whose allocation changed since the
/// walk) and regroups them by the size lstat reports; then only buckets
/// that still hold two or more files are read — first 64 KiB as a filter
/// digest, then, for the survivors, the whole file. A group is only ever
/// emitted on agreement of full content digests: same size and same head
/// digest make files *candidates*, never duplicates.
///
/// Same traversal shape as `LargeFileScanner` — a fixed pool of workers over
/// one shared queue of directories — with the same safety rules:
/// - symlinked children are neither followed nor listed (cycles, and a
///   link's target would be compared twice under two paths);
/// - mount points are skipped entirely: another volume's files belong to
///   that volume;
/// - the Trash is never entered: its contents are already marked for
///   removal, and the clean engine deletes in-Trash items outright, so
///   offering a copy that sits there would put a permanent delete behind
///   the confirmation sheet's move-to-Trash wording;
/// - `com.apple.*` system data is skipped by `FileSystem.entries`
///   (TCC-protected on macOS 26+);
/// - the volume-root plumbing markers are skipped by name at any depth;
/// - known bundle and document-package directories (`.app`, `.framework`,
///   …) and version-control metadata are never entered — their contents are
///   internals of one object, not free-standing copies a user can thin out
///   file by file;
/// - unreadable directories are counted rather than probed.
///
/// `protectedPaths` are the folders this walk refuses to enter without an
/// explicit request (the TCC-protected home trio by default), the same
/// contract the large-file walk has.
enum DuplicateFileScanner {
    /// Directories skipped as whole units. Each format is a loadable product,
    /// a document package or a project bundle: its parts are references into
    /// a structure the bundle's own manifest describes, so even a
    /// byte-identical resource inside one is not a free-standing copy a user
    /// can trash. Package formats not listed here are still entered; the list
    /// covers the formats a Mac user is likely to have.
    private static let bundleExtensions: Set<String> = [
        // Loadable products and application bundles.
        "app", "framework", "bundle", "xpc", "appex", "kext", "plugin", "docset",
        // Documents that are directories on disk.
        "pages", "numbers", "key", "rtfd", "scptd", "pkg", "mpkg",
        // Developer products and project bundles.
        "xcarchive", "xcodeproj", "xcworkspace", "playground", "dsym", "xcassets", "git",
        // Media and photo libraries.
        "photoslibrary", "photolibrary", "tvlibrary", "musiclibrary", "aplibrary",
        "imovielibrary", "fcpbundle", "logicx", "band",
        // Virtual machines and disk-image bundles.
        "vmwarevm", "parallels", "pvm", "utm", "sparsebundle",
    ]

    /// Version-control metadata is never entered. Its files are not
    /// free-standing copies — two checkouts can hold byte-identical config
    /// or index files, and trashing one quietly breaks the repository that
    /// owns it. A bare repository (`name.git`) is caught by the extension
    /// check; these names cover the working-tree metadata directories.
    private static let skippedDirectoryNames: Set<String> = [".git", ".svn", ".hg"]

    /// How much of a file the filter digest covers. Large enough that two
    /// different files rarely share both size and head digest, small enough
    /// that the pass over every candidate stays cheap; the full read below
    /// is what actually proves identity.
    private static let headByteLimit = 64 * 1024

    /// How much a full-content read pulls per chunk: large enough to keep
    /// syscall overhead off the profile, small enough to bound memory.
    private static let readChunkSize = 1 << 20

    /// Concurrent content reads during the comparison stage. Hashing is
    /// IO-bound, and a handful of readers keeps an SSD busy without
    /// displacing the rest of the system.
    private static let hashWorkers = 4

    /// Walk `root` and report every group of files with byte-identical
    /// content at or above `threshold` bytes. Cancelling the stream's
    /// consumer cancels the underlying scan.
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
    ) -> AsyncStream<DuplicateFileScanEvent> {
        AsyncStream(DuplicateFileScanEvent.self) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startedAt = ContinuousClock.now
                let progress = ScanProgressGate(continuation)
                let queue = ScanWalkQueue(root: root)
                let buckets = SizeBuckets()
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
                                buckets: buckets,
                                protectedPaths: protectedPaths,
                                threshold: threshold,
                                trashPath: trashPath,
                                progress: progress
                            )
                        }
                    }
                }
                // A cancelled scan publishes nothing: its partial list would
                // be presented as a finished one.
                if !Task.isCancelled {
                    let skipped = await compare(
                        buckets: buckets,
                        threshold: threshold,
                        progress: progress
                    )
                    if !Task.isCancelled {
                        continuation.yield(.finished(
                            unreadableDirectories: progress.unreadableCount,
                            skippedLinkedFiles: skipped
                        ))
                        MackitLog.disk.info(
                            "duplicate scan of \(root, privacy: .public): \(progress.candidateCount, privacy: .public) candidates above \(threshold, privacy: .public) bytes, \(progress.groupCount, privacy: .public) groups, \(skipped, privacy: .public) multi-link files skipped, \(progress.unreadableCount, privacy: .public) unreadable directories, took \(MackitLog.duration(.now - startedAt), privacy: .public)"
                        )
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Walk

    /// One worker of the walk pool: takes batches of directories off the
    /// shared queue until the walk is over. Same polling contract as the
    /// large-file walk — an empty queue is not the end of the walk while any
    /// worker still holds a batch.
    private static func walkThroughQueue(
        queue: ScanWalkQueue,
        buckets: SizeBuckets,
        protectedPaths: Set<String>,
        threshold: Int64,
        trashPath: String?,
        progress: ScanProgressGate
    ) async {
        while !Task.isCancelled {
            guard let batch = await queue.nextBatch() else { return }
            // Subdirectories are collected locally and pushed once per batch
            // rather than once per directory: one lock acquisition per 64
            // directories.
            var subdirectories: [String] = []
            for path in batch {
                if Task.isCancelled { break }
                walk(path, buckets: buckets, protectedPaths: protectedPaths, threshold: threshold, trashPath: trashPath, progress: progress, into: &subdirectories)
            }
            queue.push(contentsOf: subdirectories)
            queue.record()
        }
    }

    /// Enumerates one directory: retains its threshold-passing files as
    /// candidates and collects its subdirectories.
    private static func walk(
        _ path: String,
        buckets: SizeBuckets,
        protectedPaths: Set<String>,
        threshold: Int64,
        trashPath: String?,
        progress: ScanProgressGate,
        into subdirectories: inout [String]
    ) {
        progress.tick(path)
        guard let entries = FileSystem.entries(of: path) else {
            // Unreadable at all — a denied TCC prompt, a locked folder, or a
            // directory that vanished mid-walk. Counted so the page can say
            // the scan may have missed files.
            progress.unreadable()
            return
        }
        for entry in entries {
            if FileSystem.volumeMarkers.contains(entry.name) { continue }
            // A symlinked child is neither followed nor listed: not followed
            // avoids cycles and double-counting the target; not listed keeps
            // the link itself from ever becoming a candidate.
            if entry.isSymbolicLink { continue }
            if entry.isDirectory {
                // A mount point is another volume: not listed, not counted,
                // not entered.
                if entry.isMountPoint { continue }
                if protectedPaths.contains(entry.path) { continue }
                if skippedDirectoryNames.contains(entry.name) { continue }
                if isBundle(entry.name) { continue }
                // The Trash is the system's staging area for removal: its
                // contents are already marked for deletion and the clean
                // engine deletes in-Trash items outright, so a copy sitting
                // there must never be offered — the sheet would say "moved
                // to Trash" over a permanent delete, and the keep badge
                // could even point at the trashed copy. The helper also
                // covers the per-volume `.Trashes` container.
                if FileSystem.isTrashDirectory(entry.path, resolvingTo: trashPath) { continue }
                subdirectories.append(entry.path)
            } else if entry.isRegularFile, entry.logicalSize >= threshold {
                // Bucket by logical size, not allocation: identical content
                // always shares the logical size, while sparse regions or
                // compression can give two copies different allocations and
                // would otherwise hide one from the comparison. The
                // allocation is carried for display and reclaim estimates.
                progress.candidate()
                buckets.insert(Candidate(
                    path: entry.path,
                    name: entry.name,
                    parentPath: entry.parentPath,
                    logicalSize: entry.logicalSize,
                    allocatedSize: entry.allocatedSize
                ))
            }
        }
    }

    /// Whether a directory name names a bundle that must not be entered.
    private static func isBundle(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), name.index(after: dot) < name.endIndex else {
            return false
        }
        return bundleExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    // MARK: - Comparison

    /// One walked file, re-statted before any reading happens. The walk's
    /// allocation figure came from the bulk enumeration; this lstat is the
    /// check that the file still is what the walk saw, and the source of the
    /// values comparison needs: logical size, link count, vnode identity,
    /// and modification date.
    private struct Probed: Sendable {
        let candidate: Candidate
        let identity: FileSystem.NodeIdentity
        let logicalSize: Int64
        let linkCount: Int
        let modified: Date?
    }

    /// Stats the candidates of every multi-file bucket, drops the ones that
    /// cannot be honest duplicates, regroups the rest by logical size, and
    /// digests what survives. Returns the number of multi-link files that
    /// were skipped.
    private static func compare(
        buckets: SizeBuckets,
        threshold: Int64,
        progress: ScanProgressGate
    ) async -> Int {
        var skippedLinkedFiles = 0
        var probedBySize: [Int64: [Probed]] = [:]
        for bucket in buckets.multiCandidateBuckets() {
            for candidate in bucket.candidates {
                if Task.isCancelled { return skippedLinkedFiles }
                // A candidate that cannot be stat'ed or has changed since
                // the walk is not the file the user was shown; leave it out
                // rather than compare it under a stale size.
                guard let probe = probe(candidate) else { continue }
                if probe.linkCount > 1 {
                    skippedLinkedFiles += 1
                    continue
                }
                guard probe.logicalSize >= threshold else { continue }
                probedBySize[probe.logicalSize, default: []].append(probe)
            }
        }

        // Head digests, bucket by bucket. Only multi-file buckets are read;
        // a file whose size nobody shares can never be a duplicate.
        let semaphore = AsyncSemaphore(max: hashWorkers)
        var headBuckets: [HeadBucket] = []
        for size in probedBySize.keys.sorted(by: >) where probedBySize[size]?.count ?? 0 > 1 {
            guard let probed = probedBySize[size] else { continue }
            await withTaskGroup(of: (Probed, String?).self) { group in
                for entry in probed {
                    group.addTask {
                        // withPermit returns nil when the task was
                        // cancelled before it got a permit; a nil digest
                        // already means "not compared".
                        let outcome = await semaphore.withPermit { (entry, headDigest(of: entry)) }
                        return outcome ?? (entry, nil)
                    }
                }
                var digested: [(Probed, String)] = []
                for await (entry, digest) in group {
                    if let digest { digested.append((entry, digest)) }
                }
                // Sorted so a bucket's groups are emitted in a deterministic
                // order. The full-read buckets themselves finish concurrently
                // (see below), so the complete list's order is decided by the
                // model when the scan lands. Buckets that shrank to one
                // member are dropped here: their head digest is unique, so
                // no other file can possibly match and the full read would
                // be pure waste.
                let byDigest = Dictionary(grouping: digested) { $0.1 }
                for digest in byDigest.keys.sorted() {
                    guard let bucket = byDigest[digest], bucket.count > 1 else { continue }
                    let members = bucket.map(\.0)
                    headBuckets.append(HeadBucket(
                        logicalSize: size,
                        headDigest: digest,
                        members: members,
                        // A head read that covered the whole file *is* the
                        // full-content digest: nothing further to prove.
                        isDigestFinal: size <= Int64(headByteLimit)
                    ))
                }
            }
        }
        if Task.isCancelled { return skippedLinkedFiles }

        // Buckets whose digest is already final group directly; the rest go
        // through the full-content read.
        var toFullRead: [HeadBucket] = []
        for bucket in headBuckets {
            if bucket.isDigestFinal {
                emitGroups(from: bucket.members, digest: bucket.headDigest, progress: progress)
            } else {
                toFullRead.append(bucket)
            }
        }

        // The full-read budget, for the progress fraction: every byte these
        // buckets still have to give up.
        let totalToCompare = toFullRead.reduce(Int64(0)) { $0 + Int64($1.members.count) * $1.logicalSize }
        if !toFullRead.isEmpty {
            progress.startHashing(total: totalToCompare)
        }
        await withTaskGroup(of: Void.self) { group in
            for bucket in toFullRead {
                group.addTask {
                    await semaphore.withPermit {
                        await compare(bucket, progress: progress)
                    }
                }
            }
        }
        return skippedLinkedFiles
    }

    /// Full-content read of one bucket's members and the emission of the
    /// groups their digests form.
    private static func compare(_ bucket: HeadBucket, progress: ScanProgressGate) async {
        var groups: [DuplicateGroup] = []
        var byDigest: [String: [DuplicateFile]] = [:]
        for member in bucket.members {
            if Task.isCancelled { return }
            guard let digest = contentDigest(of: member) else { continue }
            progress.hashed(member.logicalSize, current: member.candidate.path)
            byDigest[digest, default: []].append(duplicateFile(for: member))
        }
        for digest in byDigest.keys.sorted() {
            guard let files = byDigest[digest], files.count > 1 else { continue }
            groups.append(DuplicateGroup(id: "\(bucket.logicalSize)-\(digest)", files: files))
        }
        for group in groups {
            progress.found(group)
        }
    }

    /// Builds the group for a bucket whose digest already covered the whole
    /// file — the short files under the head limit.
    private static func emitGroups(from members: [Probed], digest: String, progress: ScanProgressGate) {
        guard let size = members.first?.logicalSize else { return }
        let files = members.map { duplicateFile(for: $0) }
        guard files.count > 1 else { return }
        progress.found(DuplicateGroup(id: "\(size)-\(digest)", files: files))
    }

    private static func duplicateFile(for probed: Probed) -> DuplicateFile {
        DuplicateFile(
            path: probed.candidate.path,
            name: probed.candidate.name,
            size: probed.candidate.allocatedSize,
            logicalSize: probed.logicalSize,
            modified: probed.modified,
            parentPath: probed.candidate.parentPath,
            nodeIdentity: probed.identity
        )
    }

    /// Stats one candidate, or nil when it is gone, is no longer a regular
    /// file, or no longer holds the allocation the walk reported.
    private static func probe(_ candidate: Candidate) -> Probed? {
        var info = stat()
        guard lstat(candidate.path, &info) == 0 else { return nil }
        // A path that changed into a socket, FIFO or device after the walk
        // must not be opened and read as content.
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard info.st_size >= 0, info.st_nlink > 0 else { return nil }
        // Allocation is reported in 512-byte blocks; the walk's figure and
        // this one must agree, or the file changed after being listed. This
        // is not the grouping key — the size lstat reports is — but a stale
        // allocation means the walk's record of the file is stale too.
        let allocated = Int64(info.st_blocks) * 512
        guard allocated == candidate.allocatedSize else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return Probed(
            candidate: candidate,
            identity: FileSystem.NodeIdentity(device: UInt64(info.st_dev), node: UInt64(info.st_ino)),
            logicalSize: info.st_size,
            linkCount: Int(info.st_nlink),
            modified: modified
        )
    }

    /// SHA-256 over the first `headByteLimit` bytes (or the whole file when
    /// it is shorter), as lowercase hex. Nil when the file could not be read
    /// in full — a truncated read proves nothing either way.
    private static func headDigest(of probed: Probed) -> String? {
        let limit = min(headByteLimit, Int(probed.logicalSize))
        var hasher = SHA256()
        guard read(probed.candidate.path, bytes: Int64(limit), into: &hasher) else { return nil }
        return hex(hasher.finalize())
    }

    /// SHA-256 over the file's every byte, as lowercase hex. The expected
    /// byte count comes from the probe, so a file that shrinks mid-read
    /// fails the comparison instead of hashing as something else; a file
    /// that grows past the probed size is hashed over the size the scan
    /// listed.
    private static func contentDigest(of probed: Probed) -> String? {
        var hasher = SHA256()
        guard read(probed.candidate.path, bytes: probed.logicalSize, into: &hasher) else {
            return nil
        }
        return hex(hasher.finalize())
    }

    /// Reads exactly `bytes` from `path` into `hasher`, in chunks. False when
    /// the file cannot be opened or ends before the promised byte count.
    ///
    /// A short read is not an error: a local file usually fills the request,
    /// but a network or FUSE filesystem may return fewer bytes without being
    /// at EOF. Treating that as failure would silently drop a whole candidate
    /// bucket, so the loop asks for the rest.
    private static func read(_ path: String, bytes: Int64, into hasher: inout SHA256) -> Bool {
        guard bytes >= 0 else { return false }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        var remaining = bytes
        while remaining > 0 {
            if Task.isCancelled { return false }
            let chunk = min(Int64(readChunkSize), remaining)
            guard let data = try? handle.read(upToCount: Int(chunk)), !data.isEmpty else {
                return false
            }
            hasher.update(data: data)
            remaining -= Int64(data.count)
        }
        return true
    }

    private static func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// One walked file, as the walk saw it. Fileprivate because the size
    /// buckets hold it and live outside the enum.
    fileprivate struct Candidate: Sendable {
        let path: String
        let name: String
        let parentPath: String
        let logicalSize: Int64
        let allocatedSize: Int64
    }

    /// A bucket of files sharing a size and a head digest, waiting for the
    /// full-content read. `isDigestFinal` says the head read already covered
    /// every byte of the members, so this bucket needs no second pass.
    private struct HeadBucket: Sendable {
        let logicalSize: Int64
        let headDigest: String
        let members: [Probed]
        let isDigestFinal: Bool
    }
}

/// Candidates bucketed by logical size, filled by the walk's workers.
///
/// A lock rather than an actor: `insert` runs once per retained file and
/// must not serialize the workers behind an actor hop.
private final class SizeBuckets: Sendable {
    private struct State {
        var buckets: [Int64: [DuplicateFileScanner.Candidate]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func insert(_ candidate: DuplicateFileScanner.Candidate) {
        state.withLock { $0.buckets[candidate.logicalSize, default: []].append(candidate) }
    }

    /// The buckets holding two or more files, largest first. Singletons
    /// cannot be duplicates and are dropped here.
    func multiCandidateBuckets() -> [(size: Int64, candidates: [DuplicateFileScanner.Candidate])] {
        state.withLock { state in
            state.buckets
                .filter { $0.value.count > 1 }
                .sorted { $0.key > $1.key }
                .map { (size: $0.key, candidates: $0.value) }
        }
    }
}

/// Throttles progress events and totals the scan's figures.
///
/// A lock rather than an actor, the same choice as the large-file walk's
/// gate: the tick runs once per directory and an actor hop would cost a
/// suspension per directory on a walk that visits hundreds of thousands.
private final class ScanProgressGate: Sendable {
    private struct State {
        var scanned = 0
        var candidates = 0
        var unreadable = 0
        var lastWalkYield: ContinuousClock.Instant?
        var compared: Int64 = 0
        var totalToCompare: Int64 = 0
        var lastHashYield: ContinuousClock.Instant?
        var groups = 0
    }

    private let continuation: AsyncStream<DuplicateFileScanEvent>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let interval: Duration = .milliseconds(120)

    init(_ continuation: AsyncStream<DuplicateFileScanEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Records one enumerated directory and publishes progress at most once
    /// per interval. A whole-disk walk would otherwise wake the main actor
    /// thousands of times a second for a label that changes too fast to
    /// read.
    func tick(_ path: String) {
        let pending: (scanned: Int, current: String)? = state.withLock { state in
            state.scanned += 1
            let now = ContinuousClock.now
            if let lastYield = state.lastWalkYield, now - lastYield < interval { return nil }
            state.lastWalkYield = now
            return (state.scanned, path)
        }
        if let pending {
            continuation.yield(.progress(scanned: pending.scanned, current: pending.current))
        }
    }

    func candidate() {
        state.withLock { $0.candidates += 1 }
    }

    func unreadable() {
        state.withLock { $0.unreadable += 1 }
    }

    /// Publishes the comparison budget once, before the first byte is read.
    func startHashing(total: Int64) {
        state.withLock { $0.totalToCompare = total }
    }

    /// Records the bytes of one compared file and publishes progress at most
    /// once per interval.
    func hashed(_ bytes: Int64, current: String) {
        let pending: (compared: Int64, total: Int64, current: String)? = state.withLock { state in
            state.compared += bytes
            let now = ContinuousClock.now
            if let lastYield = state.lastHashYield, now - lastYield < interval { return nil }
            state.lastHashYield = now
            return (state.compared, state.totalToCompare, current)
        }
        if let pending {
            continuation.yield(.hashing(compared: pending.compared, total: pending.total, current: pending.current))
        }
    }

    /// Publishes one proven group. Not throttled: a scan finds tens of
    /// these, and each is a finished fact.
    func found(_ group: DuplicateGroup) {
        state.withLock { $0.groups += 1 }
        continuation.yield(.found(group))
    }

    var unreadableCount: Int { state.withLock { $0.unreadable } }
    var candidateCount: Int { state.withLock { $0.candidates } }
    var groupCount: Int { state.withLock { $0.groups } }
}
