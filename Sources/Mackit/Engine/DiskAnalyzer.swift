import Foundation

/// One child entry of an analyzed directory: the recursive size and entry
/// counts measured for it.
///
/// `id` is the path — unique per machine and stable across rescans, so the
/// list selection and the treemap layout can key on it. Paths come from
/// `contentsOfDirectory`, which returns realpaths, so `/var` and `/private/var`
/// spellings never produce two entries for the same directory.
struct DiskEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool

    /// Recursive allocated size in bytes.
    var size: Int64
    /// Number of direct child folders / files inside this entry.
    var folderCount: Int
    var fileCount: Int
    /// Whether the measurement has landed. Entries are listed the moment
    /// enumeration finishes — the user sees every folder immediately — and
    /// sizes stream in afterwards, biggest last.
    var isMeasured: Bool
    /// The folder exists but the process may not read it (a denied TCC
    /// prompt, or a permission-locked directory). Such a folder enumerates
    /// as empty, so without this flag its row would claim "0 B".
    var isUnreadable: Bool

    /// Total direct child count: what the left list's "N items" line shows.
    var itemCount: Int { folderCount + fileCount }
}

/// Events while analyzing one directory's children.
enum DiskEvent: Sendable {
    /// Enumeration done: these children exist, none measured yet. Sizes are
    /// zero and `isMeasured` false, so the UI can show placeholder rows while
    /// the measurements stream in.
    case listed([DiskEntry])
    /// One child measured. Children that vanished mid-scan or failed to
    /// measure emit nothing.
    case measured(DiskEntry)
    /// Every child measured.
    case finished
}

/// Read-only disk space analysis: enumerate one directory's children and
/// measure each child's recursive size and entry counts, streaming results as
/// they complete.
///
/// Deliberately per-directory rather than a whole-disk tree up front. The UI
/// only ever shows one level at a time (left list = current directory's
/// children, treemap = the selected child's children), so measuring lazily
/// bounds memory to a single level and lets the user drill into a small
/// folder without first waiting for the whole disk to be traversed.
///
/// Safety rules inherited from the cleaning engine's enumeration:
/// - `com.apple.*` children are skipped (TCC-protected on macOS 26+;
///   enumerating them pops an authorization dialog) — `FileSystem.children`
///   already applies this;
/// - unreadable directories are skipped rather than probed;
/// - symlinked children are skipped: not followed (avoids double-counting
///   `/var` against `/private/var` and avoids cycles), and the mockup's root
///   listing shows exactly this — no etc / var / tmp rows;
/// - the volume-root system markers (`.nofollow` and friends) are skipped:
///   on macOS 26+ `.nofollow` mirrors the whole volume root, so traversing it
///   counts every byte on the disk a second time (and the auto-selected
///   treemap subject would re-measure the entire disk). They are filesystem
///   plumbing, never user content.
enum DiskAnalyzer {
    /// Volume-root plumbing that must not be listed or traversed: the
    /// firmlink marker dirs (macOS 26+) and the permission-less `.file`
    /// placeholder. Skipped by name at any depth — they only ever exist at
    /// volume roots and inside `.nofollow`'s mirror of one.
    private static let systemMarkers: Set<String> = [".nofollow", ".resolve", ".vol", ".file"]

    /// Analyze one directory's children. Cancelling the stream's consumer
    /// cancels the underlying measurement task.
    static func children(of path: String) -> AsyncStream<DiskEvent> {
        AsyncStream(DiskEvent.self) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(path: path, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(path: String, continuation: AsyncStream<DiskEvent>.Continuation) async {
        let startedAt = ContinuousClock.now
        let base = FileSystem.url(path)
        var isDirectory: ObjCBool = false
        guard FileSystem.manager.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            continuation.yield(.listed([]))
            continuation.yield(.finished)
            continuation.finish()
            return
        }

        // FileSystem.children already filters com.apple.* and unreadable
        // directories; the symlink and system-marker filters are
        // analysis-specific.
        let children = FileSystem.children(of: path).filter { url in
            let name = url.lastPathComponent
            if systemMarkers.contains(name) { return false }
            return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
        }
        // Publish the whole listing up front: the user sees every row
        // immediately (the 200 GB folder included) instead of watching an
        // empty list while the biggest subtree is still being traversed.
        continuation.yield(.listed(children.map { url in
            DiskEntry(
                id: url.path,
                name: url.lastPathComponent,
                path: url.path,
                isDirectory: FileSystem.isDirectory(url),
                size: 0,
                folderCount: 0,
                fileCount: 0,
                isMeasured: false,
                isUnreadable: false
            )
        }))

        let semaphore = AsyncSemaphore(max: ScanEngine.maxConcurrentMeasurements)
        var measuredCount = 0
        var totalSize: Int64 = 0

        await withTaskGroup(of: DiskEntry?.self) { group in
            for child in children {
                group.addTask {
                    await semaphore.withPermit { await measure(child) }
                }
            }
            for await entry in group {
                if Task.isCancelled { break }
                guard let entry else { continue }
                measuredCount += 1
                totalSize += entry.size
                continuation.yield(.measured(entry))
            }
        }

        MackitLog.disk.info(
            "analyzed \(path, privacy: .public): \(measuredCount, privacy: .public) entries, \(totalSize, privacy: .public) bytes, took \(MackitLog.duration(.now - startedAt), privacy: .public)"
        )
        continuation.yield(.finished)
        continuation.finish()
    }

    /// Measure one child. Returns nil when it vanished mid-scan.
    private static func measure(_ url: URL) async -> DiskEntry? {
        guard FileSystem.manager.fileExists(atPath: url.path) else { return nil }
        let isDirectory = FileSystem.isDirectory(url)

        // A folder the process may not read — a denied TCC prompt (Documents /
        // Desktop / Downloads) or a permission-locked directory — enumerates
        // as empty once access is refused. Probing it explicitly separates
        // "denied" from "genuinely empty" so the row can say so instead of
        // reporting a lying 0 B, and the pointless recursive traversal is
        // skipped.
        var unreadable = false
        if isDirectory {
            do {
                _ = try FileSystem.manager.contentsOfDirectory(atPath: url.path)
            } catch {
                unreadable = true
            }
        }

        let counts = unreadable ? (size: Int64(0), folders: 0, files: 0) : FileSystem.allocatedSizeAndCounts(of: url)
        return DiskEntry(
            id: url.path,
            name: url.lastPathComponent,
            path: url.path,
            isDirectory: isDirectory,
            size: counts.size,
            folderCount: counts.folders,
            fileCount: counts.files,
            isMeasured: true,
            isUnreadable: unreadable
        )
    }
}
