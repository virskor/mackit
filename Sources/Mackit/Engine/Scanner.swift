import Foundation

/// Events during the scanning process, consumed by the UI in a streaming fashion.
enum ScanEvent: Sendable {
    /// The number of completed work units / total, plus a description of the current stage.
    case progress(completed: Int, total: Int, label: String)
    /// A newly discovered batch of cleanable items.
    case discovered([JunkItem])
    /// Scanning finished.
    case finished(count: Int)
}

/// A simple async semaphore that limits the number of concurrent directory
/// traversals.
///
/// Without it, the scan creates a concurrent task per entry: the single
/// `~/Library/Caches` rule alone has hundreds of entries, and traversing all
/// of them at once would exhaust file descriptors, inflate memory, and be
/// slower due to IO contention.
///
/// Waiting is cancellation-aware. `withCheckedContinuation` has no
/// cancellation support of its own, so a task parked here used to stay in the
/// queue until the semaphore happened to drain — and every one of those tasks
/// then ran its full directory walk once resumed, which is why pressing Stop
/// kept the scan walking the disk until each queued unit had been measured.
actor AsyncSemaphore {
    private var running = 0
    private let max: Int
    /// Parked waiters, keyed by an id the cancelling task can name. The id is
    /// also the FIFO order: ids increase monotonically.
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var nextWaiterID = 0

    init(max: Int) {
        precondition(max > 0, "semaphore limit must be positive")
        self.max = max
    }

    /// Runs `body` while holding a permit. Returns nil when the calling task
    /// was cancelled before it got one — the caller must then skip its work
    /// rather than hold a permit it did not use.
    func withPermit<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T? {
        guard await acquire() else { return nil }
        defer { release() }
        return await body()
    }

    private func acquire() async -> Bool {
        if running < max {
            running += 1
            return true
        }
        let id = nextWaiterID
        nextWaiterID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                // The cancellation handler may already have run — it fires
                // immediately for a task that is cancelled before it parks, and
                // it runs outside the actor, so its hop back in can lose the
                // race with this append. The park therefore checks for itself:
                // without this, a task cancelled on its way into the queue
                // would wait for a permit that nobody will hand it.
                if Task.isCancelled, let parked = waiters.removeValue(forKey: id) {
                    parked.resume(returning: false)
                }
            }
        } onCancel: {
            // Outside the actor, so the removal is a hop back in. The waiter
            // may already be gone — resumed by release() with a permit, or by
            // the check above — in which case there is nothing to undo.
            Task { await self.dequeue(id) }
        }
    }

    private func dequeue(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }

    private func release() {
        // Hand the permit directly to the oldest waiter; the running count
        // stays unchanged, because that waiter takes this permit over.
        if let id = waiters.keys.min() {
            waiters.removeValue(forKey: id)?.resume(returning: true)
        } else {
            running -= 1
        }
    }
}

/// The scanning engine: concurrently enumerate rules → compute sizes → report
/// back item by item in a stream. All are `nonisolated` static functions,
/// avoiding the extra complexity of actor isolation.
enum ScanEngine {
    /// The maximum number of concurrent size computations. Directory traversal
    /// is IO-bound; going above this number only adds file descriptor and
    /// memory pressure without being faster.
    static let maxConcurrentMeasurements = 6

    static func scan(rules: [ScanRule], cliRules: [CLIRule], options: ScanOptions) -> AsyncStream<ScanEvent> {
        AsyncStream(ScanEvent.self) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(rules: rules, cliRules: cliRules, options: options, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Main flow

    private static func run(
        rules: [ScanRule],
        cliRules: [CLIRule],
        options: ScanOptions,
        continuation: AsyncStream<ScanEvent>.Continuation
    ) async {
        let units = buildUnits(rules: rules, cliRules: cliRules, options: options)
        guard !units.isEmpty else {
            continuation.yield(.finished(count: 0))
            continuation.finish()
            return
        }

        var totalFound = 0
        let semaphore = AsyncSemaphore(max: maxConcurrentMeasurements)

        await withTaskGroup(of: (label: String, items: [JunkItem]).self) { group in
            for unit in units {
                group.addTask {
                    await scanUnit(unit, semaphore: semaphore)
                }
            }

            var completed = 0
            for await result in group {
                if Task.isCancelled { break }
                completed += 1
                // The label comes from the unit that just finished: execution
                // within the group is concurrent, so the completion order has
                // nothing to do with the group construction order, and indexing
                // units by completed would point to a unit that has not
                // finished measuring yet.
                continuation.yield(.progress(completed: completed, total: units.count, label: result.label))
                if !result.items.isEmpty {
                    totalFound += result.items.count
                    continuation.yield(.discovered(result.items))
                }
            }
        }

        continuation.yield(.finished(count: totalFound))
        continuation.finish()
    }

    // MARK: - Work units

    private struct ScanUnit: Sendable {
        let label: String
        let item: JunkItem

        init(label: String, item: JunkItem) {
            self.label = label
            self.item = item
        }

        /// Command-line cleaning items form their own group because they do not enumerate the file system.
        static func cli(_ rule: CLIRule) -> ScanUnit {
            let hintSize = rule.sizeHints.reduce(Int64(0)) { partial, hint in
                partial + FileSystem.allocatedSize(of: FileSystem.url(hint))
            }
            let item = JunkItem(
                ruleID: rule.id,
                title: rule.title,
                detail: rule.note,
                path: "",
                category: rule.category,
                risk: rule.risk,
                size: hintSize,
                isCommand: true,
                command: ([rule.executable] + rule.arguments)
            )
            // The scan phase only measures sizeHints; the command is not executed, so the label cannot say "execute".
            return ScanUnit(label: L10n.fmt("scan.measuring", rule.title), item: item)
        }
    }

    private static func buildUnits(rules: [ScanRule], cliRules: [CLIRule], options: ScanOptions) -> [ScanUnit] {
        var units: [ScanUnit] = []

        for rule in rules {
            let urls = urls(for: rule)
            guard !urls.isEmpty else { continue }
            for url in urls {
                let item = JunkItem(
                    ruleID: rule.id,
                    title: rule.displayName(for: url),
                    detail: rule.title,
                    path: url.path,
                    category: rule.category,
                    risk: rule.risk,
                    isDirectory: FileSystem.isDirectory(url)
                )
                // Each entry becomes its own work unit: measurements complete
                // one by one, and returning a whole rule's batch at once would
                // let large directories (hundreds of MB to several GB) hold the
                // batch of results back for minutes; splitting them lets items
                // stream into the list as their measurements complete.
                units.append(ScanUnit(label: rule.title, item: item))
            }
        }

        if options.includeCLI {
            for rule in cliRules {
                // Skip directly when the command-line tool does not exist, to avoid an entry that can never be executed.
                guard ToolLocator.resolve(rule.executable) != nil else { continue }
                units.append(ScanUnit.cli(rule))
            }
        }

        return units
    }

    /// Take the URL list for a rule; returns empty when the directory does not exist.
    private static func urls(for rule: ScanRule) -> [URL] {
        switch rule.target {
        case .children(let path):
            return FileSystem.children(of: path)
        case .directory(let path):
            let url = FileSystem.url(path)
            return FileSystem.manager.fileExists(atPath: url.path) ? [url] : []
        case .glob(let pattern):
            return FileSystem.expand(pattern: pattern)
        }
    }

    /// Compute the size and report it back. Size computation is throttled by the semaphore to avoid opening too many directories at once.
    private static func scanUnit(_ unit: ScanUnit, semaphore: AsyncSemaphore) async -> (label: String, items: [JunkItem]) {
        // A nil here is either a cancelled wait for a permit or a path that
        // vanished mid-scan; both mean this unit contributes no item.
        guard let measured = await semaphore.withPermit({ await measure(unit.item) }) else {
            return (unit.label, [])
        }
        return (unit.label, [measured].compactMap { $0 })
    }

    private static func measure(_ item: JunkItem) async -> JunkItem? {
        guard !item.path.isEmpty else { return item }
        // A scan told to stop must not keep walking directories it has already
        // abandoned: the unit may have been queued behind hundreds of others
        // and only reached its permit long after the cancel.
        if Task.isCancelled { return nil }
        let url = URL(fileURLWithPath: item.path)
        guard FileSystem.manager.fileExists(atPath: url.path) else { return nil }
        let result = FileSystem.allocatedSizeAndDate(of: url)
        var copy = item
        copy.size = result.size
        copy.modified = result.date
        return copy
    }

    // MARK: - Project directory scanning

    /// Fill in size and modification time for any batch of entries.
    ///
    /// Shares the same semaphore limit as the main scan: a project root can
    /// turn up hundreds of artifact directories at once, and without
    /// throttling hundreds of directory traversals would run concurrently,
    /// with file descriptors and IO contention both going out of control.
    static func measure(_ items: [JunkItem]) async -> [JunkItem] {
        let semaphore = AsyncSemaphore(max: maxConcurrentMeasurements)
        return await withTaskGroup(of: JunkItem?.self) { group in
            for item in items {
                group.addTask {
                    // Flattened here: the outer nil is the cancelled permit, the
                    // inner one is a path that no longer exists.
                    guard let measured = await semaphore.withPermit({ await measure(item) }) else { return nil }
                    return measured
                }
            }
            var measured: [JunkItem] = []
            measured.reserveCapacity(items.count)
            for await result in group {
                if let result { measured.append(result) }
            }
            return measured
        }
    }

    /// Traverse the project root to find common build artifact directories.
    static func scanProjectJunk(
        root: String,
        names: [String],
        maxDepth: Int
    ) -> [JunkItem] {
        let rootURL = FileSystem.url(root)
        var isDirectory: ObjCBool = false
        guard FileSystem.manager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        let wanted = Set(names)
        var found: [JunkItem] = []
        // Keyed by vnode, not by path spelling: the same directory reached
        // through a symlink or a second path is still one subtree, and walking
        // it once per spelling measures the same bytes repeatedly.
        var visited: Set<FileSystem.NodeIdentity> = []
        if let rootIdentity = FileSystem.identity(ofPath: rootURL.path) {
            visited.insert(rootIdentity)
        }

        // Breadth-first with limited depth, to avoid traversing the whole disk.
        // The queue uses a cursor rather than removeFirst(): with many directories,
        // removeFirst moves the whole array every step, degrading BFS to O(n²).
        var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]
        var head = 0
        while head < queue.count {
            let (url, depth) = queue[head]
            head += 1
            guard depth < maxDepth else { continue }
            guard let children = try? FileSystem.manager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsSubdirectoryDescendants]
            ) else { continue }

            for child in children {
                let name = child.lastPathComponent
                if wanted.contains(name), FileSystem.isDirectory(child) {
                    let risk: RiskLevel = ProjectJunkNames.reviewed.contains(name) ? .review : .safe
                    found.append(
                        JunkItem(
                            ruleID: "project.\(name)",
                            title: name,
                            detail: relativeProjectPath(rootURL: rootURL, url: child),
                            path: child.path,
                            category: .projects,
                            risk: risk,
                            isDirectory: true
                        )
                    )
                    // Do not descend further after finding a target; node_modules can contain tens of thousands of directories.
                    continue
                }
                // A symlinked directory is not descended into: it is not the
                // project's own directory, and a self-referential link would
                // otherwise be walked once per depth level, each under a fresh
                // spelling. On the local filesystems `contentsOfDirectory`
                // refuses to open a symlink at all (ENOTDIR, verified), so this
                // is explicit intent rather than a live fix — but that refusal
                // is a filesystem behavior, not a documented guarantee, and a
                // network mount may well follow the link.
                guard !FileSystem.isSymbolicLink(child), FileSystem.isDirectory(child) else { continue }
                if name.hasPrefix(".") { continue } // Skip hidden directories
                // Deduplicated by vnode, not by path spelling: the same
                // directory reached through a second path — a bind mount, a
                // firmlink alias — is still one subtree, and walking it once per
                // spelling measures the same bytes repeatedly.
                guard let identity = FileSystem.identity(ofPath: child.path),
                      visited.insert(identity).inserted else { continue }
                queue.append((child, depth + 1))
            }
        }

        return found
    }

    private static func relativeProjectPath(rootURL: URL, url: URL) -> String {
        let root = rootURL.path
        guard url.path.hasPrefix(root) else { return url.path }
        var relative = String(url.path.dropFirst(root.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return L10n.fmt("projects.relativePath", relative)
    }
}
