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
actor AsyncSemaphore {
    private var running = 0
    private let max: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(max: Int) {
        precondition(max > 0, "信号量上限必须为正数")
        self.max = max
    }

    func withPermit<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        if running < max {
            running += 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        defer { release() }
        return await body()
    }

    private func release() {
        if !waiters.isEmpty {
            // Hand the permit directly to a waiter; the running count stays unchanged
            waiters.removeFirst().resume()
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
        let measured = await semaphore.withPermit { await measure(unit.item) }
        guard let measured else { return (unit.label, []) }
        return (unit.label, [measured])
    }

    private static func measure(_ item: JunkItem) async -> JunkItem? {
        guard !item.path.isEmpty else { return item }
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
                group.addTask { await semaphore.withPermit { await measure(item) } }
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
        var visited: Set<String> = [rootURL.path]

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
                guard FileSystem.isDirectory(child) else { continue }
                if name.hasPrefix(".") { continue } // Skip hidden directories
                if !visited.insert(child.path).inserted { continue }
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
