import SwiftUI

/// State model for the disk analysis tool page.
///
/// The page has three screens: a start screen before anything has been
/// measured, a scanning screen while a measurement runs, and the results once
/// it has. Entering the tool never starts a scan on its own — a whole-disk
/// traversal is minutes of IO the user did not ask for, so the first visit
/// shows the start screen and the user presses the button. Every later
/// measurement — a rescan, a drill-down past the depth budget, an explicitly
/// approved protected folder — runs the same scan-then-present flow. Nothing
/// streams in incrementally: a half-measured list invites the user to read
/// numbers that are still moving.
///
/// Navigation is a walk over the scanned tree. Because every browsed level is
/// already measured, drilling down, going back and jumping through the
/// breadcrumb are instant — there is no per-directory cache to keep warm and
/// no measurement task behind the views.
@MainActor
@Observable
final class DiskAnalysisModel {
    // MARK: Scan state

    private(set) var isScanning = false
    /// The directory being measured right now, for the scanning screen.
    private(set) var scanCurrentPath = ""
    /// Directories measured so far. A whole-disk scan's total is unknown up
    /// front, so this is a count, not a fraction.
    private(set) var scannedDirectories = 0
    /// How long the in-flight measurement has been running, republished by a
    /// timer so the readout keeps moving between progress events (which are
    /// throttled to ~8 per second and can stop entirely while one large
    /// directory is being measured).
    private(set) var scanElapsed: Duration = .zero
    /// The directory count a previous scan of this tree ended on — the
    /// denominator for `scanFraction` and `scanRemaining`. Nil when this tree
    /// was never scanned before (or the skip set changed since it was), and
    /// then the screen sweeps instead of pretending to know the total.
    private(set) var scanEstimatedTotal: Int?

    /// Fraction of the estimated total measured so far, or nil when the total
    /// is unknown.
    var scanFraction: Double? {
        guard let total = scanEstimatedTotal, total > 0 else { return nil }
        return min(1, Double(scannedDirectories) / Double(total))
    }

    /// Time left, from the rate measured so far. Nil until there is enough to
    /// estimate from: the first seconds of a traversal are unrepresentative
    /// (the shallow levels fly, then the first huge directory parks the rate),
    /// and a number that jumps around is worse than none at all.
    var scanRemaining: Duration? {
        Self.remainingEstimate(
            elapsed: scanElapsed,
            scanned: scannedDirectories,
            total: scanEstimatedTotal ?? 0
        )
    }

    /// The estimate itself, pure so the threshold and the arithmetic can be
    /// tested without a scan. Linear extrapolation of the running rate:
    /// `elapsed / scanned` per directory, times the directories left.
    static func remainingEstimate(elapsed: Duration, scanned: Int, total: Int) -> Duration? {
        // Two floors, because either alone lets a bad rate through. The
        // directory count alone is reached within the first second of a
        // whole-disk scan, while only the shallow levels have been visited —
        // those fly, so the extrapolation would promise seconds for a
        // two-minute scan. The elapsed floor alone is met by a long crawl
        // through one huge directory, where the count says nothing yet.
        // Kept as separate guards: a comma-separated condition list reads
        // `scanned < total, elapsed > .zero` as a generic argument list.
        guard scanned >= Self.estimateMinimumSample else { return nil }
        guard elapsed >= Self.estimateMinimumElapsed else { return nil }
        guard scanned < total else { return nil }
        let perDirectory = elapsed / Double(scanned)
        return perDirectory * Double(total - scanned)
    }

    /// Directories to measure before a remaining time is shown. Small trees
    /// finish long before this and simply never get an estimate — for them the
    /// elapsed readout is the whole story.
    private static let estimateMinimumSample = 2_000

    /// Time to measure for before a remaining time is shown, so the rate the
    /// estimate extrapolates has seen past the fast shallow levels.
    private static let estimateMinimumElapsed: Duration = .seconds(10)

    // MARK: The scanned tree

    /// The scanned tree, rooted at the startup disk (a fixture in tests). nil
    /// until the first scan lands — or again after a rescan drops it.
    private(set) var root: DiskEntry?
    /// The directory being browsed.
    private(set) var currentPath: String

    /// Breadcrumb root-first; every entry but the last is a button that jumps
    /// back to that level. Rebuilt from the tree on every navigation, so a
    /// treemap tile's parent level is always part of the path.
    private(set) var breadcrumb: [DiskEntry] = []
    /// The current directory's children, size descending.
    private(set) var children: [DiskEntry] = []
    private(set) var selectedID: String?
    /// The selected child — the treemap's subject. Recomputed on every
    /// navigation and tree mutation so the views never walk the tree
    /// themselves: a directory can hold a hundred thousand children, and a
    /// view body must not scan them.
    private(set) var selectedEntry: DiskEntry?

    /// The directory being browsed, as a tree node.
    var currentEntry: DiskEntry? { breadcrumb.last }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    // MARK: View state

    /// Treemap visualization on, plain list off.
    var visualizationMode: Bool = true

    /// Startup disk usage, shown in the page title.
    var volumeUsage: VolumeUsage = .home()

    private let rootPath: String
    /// Test seam: the real home folder, or a fixed one inside a fixture.
    private let homeOverride: String?
    /// Depth budget handed to every scan. A parameter so tests can pin the
    /// truncation boundary with a shallow fixture.
    private let maxDepth: Int
    /// Remembers past scans' directory counts, so a rescan of the same tree
    /// can show a fraction and a remaining time.
    private let history: ScanProgressHistory

    private var backStack: [String] = []
    private var forwardStack: [String] = []

    private var scanTask: Task<Void, Never>?
    /// The concurrent directory count that supplies the denominator when the
    /// history has none for this tree.
    private var countTask: Task<Void, Never>?
    /// Ticks `scanElapsed` while a measurement runs.
    private var elapsedTimer: Task<Void, Never>?
    /// When the in-flight measurement started.
    private var scanStartedAt: ContinuousClock.Instant?
    /// Generation counter for the measurement stream. Starting a scan cancels
    /// the in-flight one, but cancellation is cooperative — a task sitting
    /// between two events can still deliver one more. Tagging each scan with
    /// a generation and dropping stale events keeps a cancelled scan's
    /// leftovers out of the new results.
    private var scanGeneration = 0

    /// Folders the user has explicitly scanned despite the TCC skip. Once
    /// approved, later scans of the same parent include them without asking
    /// again — the system's own grant persists, so re-approval is instant.
    private var approvedPaths: Set<String> = []

    init(
        rootPath: String = "/",
        homePath: String? = nil,
        maxDepth: Int = DiskAnalyzer.maxDepth,
        history: ScanProgressHistory = ScanProgressHistory()
    ) {
        self.rootPath = rootPath
        self.homeOverride = homePath
        self.maxDepth = maxDepth
        self.history = history
        self.currentPath = rootPath
    }

    // MARK: Lifecycle

    /// Called when the sidebar selects the tool. Never starts a measurement:
    /// a finished tree restores instantly, so coming back is free, and a
    /// first visit leaves the start screen up for the user to press. The one
    /// thing it does resume is a browsed folder whose children the tree does
    /// not hold — the user asked for that one by navigating into it.
    func activate() {
        volumeUsage = .home()
        ensureCurrentScanned()
    }

    /// Stops the in-flight measurement. The page keeps whatever the tree
    /// already holds: a stopped whole-disk scan leaves the tool unscanned, a
    /// stopped subtree scan leaves that folder unexpanded — both say so and
    /// offer the scan again. Also called when the user navigates to another
    /// page: measurement burns IO and CPU, and nobody is watching the result.
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        countTask?.cancel()
        countTask = nil
        stopElapsedTimer()
        // The task is gone, so the flag must go too — otherwise the page
        // would stay on the scanning screen with nothing to stop.
        isScanning = false
    }

    // MARK: Navigation actions

    /// The user's home folder: the toolbar's shortcut target, and the fastest
    /// path to ~/Library/Containers where most reclaimable container junk
    /// lives.
    var homePath: String { homeOverride ?? FileSystem.expand("~") }

    /// The home folder's display name (the account name), for the shortcut's
    /// label.
    var homeName: String { URL(fileURLWithPath: homePath).lastPathComponent }

    /// Jumps straight to the user's home folder.
    func goToHome() {
        let home = homePath
        // The shortcut only moves inside the analyzed tree, and the home node
        // has to be in it: jumping to a path the scan never measured would
        // leave the breadcrumb pointing at nothing.
        guard home != rootPath, home != currentPath, home.hasPrefix(rootPath) else { return }
        navigate(to: home)
    }

    /// Enters a folder (a row's or a treemap tile's double-click). A file is
    /// selected instead — there is nothing to enter.
    func enter(_ entry: DiskEntry) {
        guard entry.isDirectory else { select(entry.id); return }
        // A skipped folder isn't navigable until it has been scanned: route
        // the double-click to a selection so the detail explains and offers
        // the explicit scan action.
        if entry.isSkipped { select(entry.id); return }
        // A treemap tile is a child of the *selected* entry, not of the
        // browsed directory. The breadcrumb is walked from the tree, so the
        // tile's parent stays in the path (root › big › nested) while the
        // history only ever records the browsed path — back from the tile
        // returns to where the drill-down started.
        navigate(to: entry.path)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        go(to: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        go(to: next)
    }

    /// Jumps to a breadcrumb segment (the root's index is 0). Segments after
    /// it are dropped from the history.
    func navigateToBreadcrumb(index: Int) {
        guard index >= 0, index < breadcrumb.count - 1 else { return }
        backStack.append(currentPath)
        forwardStack.removeAll()
        go(to: breadcrumb[index].path)
    }

    // MARK: Selection

    func select(_ id: String?) {
        // Only an id from the current listing can be selected. A row's
        // double-click fires the button's select *after* the enter gesture,
        // and that stale id — the folder just entered, no longer among its
        // own children — would otherwise dangle as a selection with nothing
        // left to show, blanking the treemap.
        guard let id, id != selectedID, let match = children.first(where: { $0.id == id }) else { return }
        selectedID = id
        selectedEntry = match
    }

    // MARK: Actions

    /// The start screen's button, and what the toolbar's rescan does while
    /// nothing has been measured yet: a whole-disk scan from scratch. The
    /// tree is dropped — sizes anywhere may have gone stale since the last
    /// scan, and keeping them would show numbers the user just asked to
    /// re-measure.
    func startScan() {
        startScan(at: rootPath)
    }

    /// The toolbar button: stops an in-flight scan, otherwise starts a fresh
    /// whole-disk one. A rescan drops the tree — sizes anywhere may have gone
    /// stale since the last visit, and keeping them would show numbers the
    /// user just asked to re-measure.
    func rescanOrStop() {
        if isScanning {
            cancelScan()
            return
        }
        startScan()
    }

    /// Scans one folder on explicit request — a TCC-protected home folder the
    /// default scan skips, or a folder whose children the depth budget did
    /// not retain. The system's one-time access prompt is now user-initiated:
    /// the whole point of skipping is that it never fires unprompted mid-scan.
    func scanFolder(_ entry: DiskEntry) {
        guard entry.isDirectory else { return }
        if entry.isSkipped {
            // Once approved, later scans of the same parent include it without
            // asking again — the system's own grant persists.
            approvedPaths.insert(entry.path)
        }
        startScan(at: entry.path)
    }

    /// Scans the folder being browsed when its children are not in the tree —
    /// either the depth budget cut them or a previous scan was stopped.
    func scanCurrentFolder() {
        guard let node = breadcrumb.last else { return }
        scanFolder(node)
    }

    /// Shows the entry in Finder.
    ///
    /// Revealing *through* Finder is an AppleEvent, and an app that may not
    /// automate Finder — an ad-hoc build, or a user who declined the prompt
    /// — gets silence rather than an error, so the click reads as a no-op.
    /// LaunchServices needs no such permission: a folder opens itself and a
    /// file opens in its enclosing folder, and either way the target is on
    /// screen. That is also why the unreadable and skipped folders need no
    /// special case here — Finder opens them with its own permissions.
    func revealInFinder(_ entry: DiskEntry) {
        let url = URL(fileURLWithPath: entry.path)
        let target = entry.isDirectory ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.open(target)
    }

    // MARK: Icons

    /// Folder icons, cached per path: `NSWorkspace.icon` is not free, and the
    /// list re-renders on every observation change. The same cache serves the
    /// rows, the breadcrumb's disk icon and the treemap tiles.
    ///
    /// Capped: a long drilling session visits thousands of paths, and each
    /// NSImage carries its full representation set. Eviction is FIFO — an icon
    /// is a few syscalls to rebuild, so the policy only has to be cheap.
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var iconCacheOrder: [String] = []
    private let iconCacheCapacity = 128

    func icon(forPath path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if iconCacheOrder.count >= iconCacheCapacity {
            iconCache.removeValue(forKey: iconCacheOrder.removeFirst())
        }
        iconCacheOrder.append(path)
        iconCache[path] = icon
        return icon
    }

    // MARK: Tree navigation

    /// The nodes from the root down to `path`, or nil when the path is not in
    /// the scanned tree.
    private func spine(to path: String) -> [DiskEntry]? {
        guard let root else { return nil }
        // "/" is its own prefix; every other root needs the separator so
        // "/base" does not match "/basement/x".
        let base = root.path == "/" ? "/" : root.path + "/"
        guard path == root.path || path.hasPrefix(base) else { return nil }
        var spine = [root]
        var node = root
        if path == root.path { return spine }
        var prefix = root.path
        for component in String(path.dropFirst(root.path.count)).split(separator: "/") {
            prefix = prefix == "/" ? "/\(component)" : "\(prefix)/\(component)"
            guard let next = node.children.first(where: { $0.path == prefix }) else { return nil }
            spine.append(next)
            node = next
        }
        return spine
    }

    /// Republishes everything the views read for one spine: the breadcrumb,
    /// the children, and the treemap's subject.
    private func publish(spine: [DiskEntry]) {
        breadcrumb = spine
        children = spine.last?.children ?? []
        if let id = selectedID, let match = children.first(where: { $0.id == id }) {
            selectedEntry = match
        } else if let largest = children.first {
            // Entering a folder selects its largest child by default, so the
            // treemap immediately shows where the space actually went —
            // picking the first enumerated child would show a random one.
            // Skipped and unreadable children have no size, so they sort last
            // and never win this.
            selectedID = largest.id
            selectedEntry = largest
        } else {
            selectedEntry = nil
        }
    }

    /// Navigates to a directory that is already in the tree, recording the
    /// move in the history. Returns false — leaving everything as it was —
    /// when the path was never scanned.
    @discardableResult
    private func navigate(to path: String) -> Bool {
        guard spine(to: path) != nil else { return false }
        backStack.append(currentPath)
        forwardStack.removeAll()
        go(to: path)
        return true
    }

    /// Moves to an already-scanned directory without touching the history
    /// stacks (the caller manages them).
    private func go(to path: String) {
        guard let spine = spine(to: path) else { return }
        currentPath = path
        publish(spine: spine)
        ensureCurrentScanned()
    }

    /// Republishes after a tree mutation. The walk cannot fail — grafting only
    /// replaces a node that was already in the tree — but if it ever did, the
    /// page would keep its pre-graft listing rather than blanking out.
    private func refreshFromTree() {
        if let spine = spine(to: currentPath) { publish(spine: spine) }
    }

    /// The browsing directory's children must be in the tree: a folder whose
    /// children the scan did not retain is scanned now — the same
    /// scanning-screen-then-results flow the whole disk got. Skipped folders
    /// are left alone: measuring one pops the system access dialog, and the
    /// whole point of skipping is that it never fires unprompted. The detail
    /// area offers the explicit action instead.
    private func ensureCurrentScanned() {
        guard let node = breadcrumb.last else { return }
        guard node.isDirectory, !node.isSkipped, !node.isUnreadable, node.isTruncated else { return }
        startScan(at: node.path)
    }

    // MARK: Measurement

    private func startScan(at path: String) {
        scanTask?.cancel()
        countTask?.cancel()
        if path == rootPath {
            // A whole-disk scan — the first one, or a rescan — starts over:
            // the tree is dropped and the navigation reset, and the scanning
            // screen gets a synthesized root so the breadcrumb is not empty
            // while the disk is measured.
            root = nil
            currentPath = rootPath
            selectedID = nil
            backStack.removeAll()
            forwardStack.removeAll()
            breadcrumb = [rootPlaceholder()]
            children = []
            selectedEntry = nil
        }
        isScanning = true
        scanCurrentPath = path
        scannedDirectories = 0
        scanElapsed = .zero
        scanStartedAt = .now
        // A rescan of a tree measured before divides by the count that scan
        // ended on, so the ring fills and the remaining line estimates. The
        // signature is part of the lookup: a scan that skips different folders
        // visits a different number of directories.
        scanEstimatedTotal = history.directoryCount(for: path, signature: skipSignature)
        startElapsedTimer()
        scanGeneration += 1
        let generation = scanGeneration
        let protectedPaths = skipPaths
        let maxDepth = self.maxDepth
        scanTask = Task { [weak self] in
            guard let self else { return }
            let stream = DiskAnalyzer.scan(root: path, protectedPaths: protectedPaths, maxDepth: maxDepth)
            for await event in stream {
                if Task.isCancelled { return }
                guard generation == self.scanGeneration else { return }
                switch event {
                case .progress(let scanned, let current):
                    self.scannedDirectories = scanned
                    self.scanCurrentPath = current
                case .finished(let node, let directories):
                    self.applyScan(node, directories: directories, at: path)
                }
            }
            // The stream only ends after .finished, or after a cancel (which
            // already cleared the flag). The generation guard keeps a stale
            // task from clearing a newer scan's flag; the reset keeps a scan
            // from ever leaving the page stuck on the scanning screen.
            guard !Task.isCancelled, generation == self.scanGeneration else { return }
            self.isScanning = false
        }
        if scanEstimatedTotal == nil {
            // Nothing remembered for this tree — a first scan, or a changed
            // skip set — so count it while the measurement runs. The count is
            // metadata-only and finishes well inside the measurement; until it
            // lands the ring sweeps, and the moment it lands the fraction and
            // the remaining estimate become real.
            let protectedPaths = skipPaths
            countTask = Task { [weak self] in
                guard let self else { return }
                let count = await DiskAnalyzer.countDirectories(root: path, protectedPaths: protectedPaths)
                guard !Task.isCancelled, generation == self.scanGeneration else { return }
                self.scanEstimatedTotal = count > 0 ? count : nil
                self.countTask = nil
            }
        }
    }

    /// Keeps `scanElapsed` moving while a measurement runs. The progress
    /// events are throttled and can pause entirely while one large directory
    /// is measured, so without this the elapsed readout would freeze in jumps
    /// — exactly when the user is most likely staring at it.
    private func startElapsedTimer() {
        // Cancels the task inline rather than through `stopElapsedTimer`:
        // that also clears the start instant, which this scan just recorded.
        elapsedTimer?.cancel()
        elapsedTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.tickElapsed()
            }
        }
    }

    /// Publishes the in-flight measurement's elapsed time. Called by the
    /// timer; a no-op once the measurement it belongs to has stopped, so a
    /// late tick cannot resurrect a finished scan's clock. Visible within the
    /// module so the readout can be tested without waiting on real time.
    func tickElapsed() {
        guard let startedAt = scanStartedAt else { return }
        scanElapsed = .now - startedAt
    }

    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
        scanStartedAt = nil
    }

    private func applyScan(_ node: DiskEntry, directories: Int, at path: String) {
        isScanning = false
        stopElapsedTimer()
        volumeUsage = .home()
        // Remember the count as this tree's denominator: the next scan of the
        // same root with the same skip set divides by it.
        history.record(root: path, signature: skipSignature, directories: directories)
        if path == rootPath {
            root = node
            root?.name = rootDisplayName
        } else if let root {
            // Graft the freshly measured subtree over the truncated (or
            // skipped) placeholder it came from: same path, now carrying its
            // children — which is what promotes the row from "not scanned".
            self.root = Self.graft(node, into: root)
        }
        refreshFromTree()
    }

    /// Replaces the node at `node.path` with `node`, rebuilding only the
    /// spine: Swift arrays are copy-on-write, so a deep graft copies the path
    /// from the root down, not the whole tree.
    private static func graft(_ node: DiskEntry, into parent: DiskEntry) -> DiskEntry {
        guard parent.path != node.path else { return node }
        // Only a child on the target's path can hold it; everything else is
        // returned untouched, so the walk costs the spine, not the tree.
        guard parent.children.contains(where: { $0.path == node.path || node.path.hasPrefix($0.path + "/") }) else {
            return parent
        }
        var parent = parent
        parent.children = parent.children.map { child in
            guard child.path == node.path || node.path.hasPrefix(child.path + "/") else { return child }
            return child.path == node.path ? node : graft(node, into: child)
        }
        return parent
    }

    // MARK: Root entry

    /// The breadcrumb's root entry before the tree exists (and the title the
    /// finished tree's root is renamed to): the volume's display name and
    /// used space.
    private func rootPlaceholder() -> DiskEntry {
        DiskEntry(
            path: rootPath,
            name: rootDisplayName,
            isDirectory: true,
            size: volumeUsage.used,
            folderCount: 0,
            fileCount: 0,
            children: [],
            isUnreadable: false,
            isSkipped: false,
            isTruncated: false
        )
    }

    private var rootDisplayName: String {
        guard let name = (try? FileSystem.url(rootPath).resourceValues(forKeys: [.volumeNameKey]))?.volumeName,
              !name.isEmpty else {
            return L10n.tr("diskAnalysis.disk")
        }
        return name
    }

    /// The folders this session refuses to scan without an explicit request:
    /// the TCC-protected home trio, minus any the user has approved. Entering
    /// one pops the system access dialog, so a full-disk scan skips them and
    /// their rows say "not scanned" until the user asks.
    ///
    /// Both spellings of each path go in: the listing layer yields paths as
    /// spelled by the traversal's base URL, while `canonical` resolves
    /// firmlinks and symlinks — on a machine where the two differ, a set
    /// built from one spelling alone would never match the other.
    private var skipPaths: Set<String> {
        var paths: Set<String> = []
        for name in ["Documents", "Desktop", "Downloads"] {
            let raw = homePath + "/" + name
            paths.insert(raw)
            let resolved = FileSystem.canonical(raw)
            if resolved != raw { paths.insert(resolved) }
        }
        return paths.subtracting(approvedPaths.flatMap { [$0, FileSystem.canonical($0)] })
    }

    /// Identity of the skip set this session scans with, for the progress
    /// history lookup: a remembered directory count is only a valid
    /// denominator for a scan that enters the same folders. Approving a
    /// TCC-protected folder changes it, so the count is not reused.
    private var skipSignature: String {
        ([String(maxDepth)] + skipPaths.sorted()).joined(separator: "\u{1F}")
    }

    // MARK: Test seam

    /// Waits until the current scan goes quiet — the measurement and, when one
    /// is running, the concurrent directory count that supplies the
    /// denominator. The flags are set synchronously by the action that starts
    /// the work, so polling them right after an action never misses them.
    func waitUntilSettled() async {
        while isScanning || countTask != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
