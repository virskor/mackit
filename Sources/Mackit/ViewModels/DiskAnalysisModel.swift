import SwiftUI

/// State model for the disk analysis tool page.
///
/// Owns navigation (breadcrumb + history), the two levels of data the page
/// shows (the current directory's children, and the selected child's children
/// for the treemap), and the measurement tasks behind them. Deliberately a
/// separate model from `AppViewModel`: analysis is a read-only tool with its
/// own lifecycle, and it must not touch the cleanup scan's phase, items, or
/// menu-bar snapshot.
///
/// Measurements are lazy and cached per directory: entering a folder that was
/// already analyzed restores its listing instantly, while the first visit
/// streams children in as their sizes land (largest rows last, since the
/// biggest subtrees take longest to traverse).
@MainActor
@Observable
final class DiskAnalysisModel {
    // MARK: Navigation

    /// The path from the startup disk down to the directory being browsed,
    /// root first. The root entry is synthesized (its size is the volume's
    /// used space); the rest are measured children of their parent.
    private(set) var breadcrumb: [DiskEntry] = []
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    // MARK: Current directory listing

    /// The current directory's children: measured entries sorted by size
    /// descending, then the still-measuring ones by name. Grows as
    /// measurements stream in; the pending block shrinks as they land.
    private(set) var children: [DiskEntry] = []
    /// Measured entries only, size descending. Kept separate from the pending
    /// block so a streamed measurement is one binary insert instead of a
    /// re-sort of the whole list.
    private var measuredChildren: [DiskEntry] = []
    /// Listed but not yet measured, name ascending.
    private var pendingChildren: [DiskEntry] = []
    private(set) var isMeasuring: Bool = false
    private(set) var measuredCount: Int = 0
    private(set) var totalCount: Int = 0
    /// The current directory exists but can't be read (permission denied).
    private(set) var unreadable: Bool = false

    // MARK: Selected child (the treemap's subject)

    private(set) var selectedID: String?
    private(set) var selectedChildren: [DiskEntry] = []
    private var selectedMeasuredChildren: [DiskEntry] = []
    private var selectedPendingChildren: [DiskEntry] = []
    private(set) var isMeasuringSelection: Bool = false
    private(set) var selectionMeasuredCount: Int = 0
    private(set) var selectionTotalCount: Int = 0
    /// The selected child is a folder that can't be read.
    private(set) var selectionUnreadable: Bool = false

    /// The selected child, if any.
    var selectedEntry: DiskEntry? {
        children.first { $0.id == selectedID }
    }

    // MARK: View state

    /// Treemap visualization on, plain list off. The mockup only shows the
    /// on state; the off state is the same data as rows.
    var visualizationMode: Bool = true

    /// Startup disk usage, shown in the page title.
    var volumeUsage: VolumeUsage = .home()

    private let rootPath: String
    /// Test seam: the real home folder, or a fixed one inside a fixture.
    private let homeOverride: String?
    private var started = false

    private var backStack: [[DiskEntry]] = []
    private var forwardStack: [[DiskEntry]] = []

    /// Measured directory listings, keyed by path. Entering a cached directory
    /// is instant, so re-visiting the same folders while drilling around never
    /// re-traverses the disk. Capped: a full-drilldown session could otherwise
    /// hold hundreds of listings (each up to thousands of entries) in memory.
    private var cache: [String: [DiskEntry]] = [:]
    private var cacheOrder: [String] = []
    private let cacheCapacity = 32

    private var directoryTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?

    /// Generation counters for the two measurement streams. Entering a folder
    /// cancels the in-flight scan, but cancellation is cooperative — a task
    /// sitting between two events can still deliver one more. Tagging each
    /// scan with a generation and dropping stale events keeps a cancelled
    /// scan's leftovers out of the new listing.
    private var directoryGeneration = 0
    private var selectionGeneration = 0

    init(rootPath: String = "/", homePath: String? = nil) {
        self.rootPath = rootPath
        self.homeOverride = homePath
    }

    // MARK: Lifecycle

    /// Called when the sidebar selects the tool: starts the root scan on the
    /// first visit, and restarts an interrupted scan on later ones (cached
    /// directories restore instantly, so coming back is cheap).
    func activate() {
        volumeUsage = .home()
        if !started {
            started = true
            breadcrumb = [rootEntry()]
            loadCurrentDirectory()
        } else if !isMeasuring && !isMeasuringSelection {
            loadCurrentDirectory()
        }
    }

    /// Called when the user navigates to any other page, or stops a scan:
    /// measurement burns IO and CPU, and nobody is watching the result. State
    /// and cache stay, so returning to the page resumes where it left off.
    func suspend() {
        directoryTask?.cancel()
        selectionTask?.cancel()
        directoryTask = nil
        selectionTask = nil
        // The tasks are gone, so the flags must go too — otherwise the
        // toolbar would stay on "Stop" forever with nothing to stop.
        isMeasuring = false
        isMeasuringSelection = false
    }

    // MARK: Navigation actions

    /// The user's home folder: the toolbar's shortcut target, and the fastest
    /// path to ~/Library/Containers where most reclaimable container junk
    /// lives.
    var homePath: String { homeOverride ?? FileSystem.expand("~") }

    /// The home folder's display name (the account name), for the shortcut's
    /// label.
    var homeName: String { URL(fileURLWithPath: homePath).lastPathComponent }

    /// The directory currently being browsed.
    var currentPath: String {
        breadcrumb.last?.path ?? rootPath
    }

    /// Jumps straight to the user's home folder. Intermediate breadcrumb
    /// entries are synthesized — the breadcrumb only renders names, and the
    /// levels below get measured as usual once entered.
    func goToHome() {
        let home = homePath
        guard home != rootPath, home != currentPath else { return }
        backStack.append(breadcrumb)
        forwardStack.removeAll()
        breadcrumb = [rootEntry()] + synthesizedEntries(along: home)
        loadCurrentDirectory()
    }

    func enter(_ entry: DiskEntry) {
        guard entry.isDirectory else { return }
        backStack.append(breadcrumb)
        forwardStack.removeAll()
        breadcrumb.append(entry)
        loadCurrentDirectory()
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(breadcrumb)
        breadcrumb = previous
        loadCurrentDirectory()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(breadcrumb)
        breadcrumb = next
        loadCurrentDirectory()
    }

    /// Jumps to a breadcrumb segment (the root's index is 0). Segments after
    /// it are dropped from the history.
    func navigateToBreadcrumb(index: Int) {
        guard index >= 0, index < breadcrumb.count - 1 else { return }
        backStack.append(breadcrumb)
        forwardStack.removeAll()
        breadcrumb = Array(breadcrumb.prefix(index + 1))
        loadCurrentDirectory()
    }

    // MARK: Selection

    func select(_ id: String?) {
        // Only an id from the current listing can be selected. A row's
        // double-click fires the button's select *after* the enter gesture,
        // and that stale id — the folder just entered, no longer among its
        // own children — would otherwise dangle as a selection with nothing
        // left to show, blanking the treemap.
        guard let id, id != selectedID, children.contains(where: { $0.id == id }) else { return }
        selectedID = id
        loadSelection()
    }

    // MARK: Actions

    /// The toolbar button: stops an in-flight measurement, otherwise starts a
    /// fresh one. A rescan drops the whole cache — sizes anywhere may have
    /// gone stale since the last visit, and keeping them would show numbers
    /// the user just asked to re-measure.
    func rescanOrStop() {
        if isMeasuring || isMeasuringSelection {
            suspend()
            return
        }
        cache.removeAll()
        cacheOrder.removeAll()
        volumeUsage = .home()
        loadCurrentDirectory()
    }

    func revealInFinder(_ entry: DiskEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    // MARK: Icons

    /// Folder icons, cached per path: `NSWorkspace.icon` is not free, and the
    /// list re-renders every time a measurement streams in. The same cache
    /// serves the rows, the breadcrumb's disk icon and the treemap tiles.
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    func icon(forPath path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    // MARK: Directory measurement

    private func loadCurrentDirectory() {
        directoryTask?.cancel()
        selectionTask?.cancel()
        selectedID = nil
        selectedChildren = []
        selectedMeasuredChildren = []
        selectedPendingChildren = []
        selectionMeasuredCount = 0
        selectionTotalCount = 0
        isMeasuringSelection = false
        selectionUnreadable = false

        let path = currentPath
        if let cached = cache[path] {
            children = cached
            measuredChildren = cached
            pendingChildren = []
            isMeasuring = false
            measuredCount = cached.count
            totalCount = cached.count
            unreadable = false
            autoSelectLargest()
            return
        }

        children = []
        measuredChildren = []
        pendingChildren = []
        measuredCount = 0
        totalCount = 0
        // A directory the process may not read (another user's home, a
        // TCC-protected location) would otherwise look identical to an empty
        // one — the listing silently comes back with nothing in it. Flag it
        // and skip the scan entirely rather than measuring nothing.
        if !FileSystem.manager.isReadableFile(atPath: path) {
            unreadable = true
            isMeasuring = false
            return
        }
        unreadable = false
        isMeasuring = true

        directoryGeneration += 1
        let generation = directoryGeneration
        directoryTask = Task { [weak self] in
            guard let self else { return }
            let stream = DiskAnalyzer.children(of: path)
            for await event in stream {
                if Task.isCancelled { return }
                guard generation == self.directoryGeneration else { return }
                self.applyDirectory(event, path: path)
            }
        }
    }

    private func applyDirectory(_ event: DiskEvent, path: String) {
        switch event {
        case .listed(let entries):
            totalCount = entries.count
            measuredCount = 0
            unreadable = false
            pendingChildren = entries.sorted { $0.name < $1.name }
            children = measuredChildren + pendingChildren

        case .measured(let entry):
            measuredCount += 1
            pendingChildren.removeAll { $0.id == entry.id }
            insert(entry, into: &measuredChildren)
            children = measuredChildren + pendingChildren

        case .finished:
            isMeasuring = false
            // A child that vanished mid-scan never got measured; drop its row
            // rather than leaving a permanent placeholder.
            pendingChildren = []
            children = measuredChildren
            storeInCache(path, children)
            autoSelectLargest()
        }
    }

    /// Inserts a measured entry into a size-descending list via binary
    /// search: re-sorting on every arrival would make a directory with
    /// thousands of children O(n² log n) to fill in.
    private func insert(_ entry: DiskEntry, into list: inout [DiskEntry]) {
        var low = 0
        var high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].size >= entry.size {
                low = mid + 1
            } else {
                high = mid
            }
        }
        list.insert(entry, at: low)
    }

    /// Entering a folder selects its largest child by default, so the treemap
    /// immediately shows where the space actually went — picking the first
    /// enumerated child would show a random one. Skipped when the user
    /// already picked something while the scan was running.
    private func autoSelectLargest() {
        guard selectedID == nil, let largest = children.first else { return }
        selectedID = largest.id
        loadSelection()
    }

    // MARK: Selection measurement

    private func loadSelection() {
        selectionTask?.cancel()
        selectedChildren = []
        selectedMeasuredChildren = []
        selectedPendingChildren = []
        selectionMeasuredCount = 0
        selectionTotalCount = 0
        isMeasuringSelection = false
        selectionUnreadable = false

        guard let id = selectedID, let entry = children.first(where: { $0.id == id }) else { return }
        // A file has no children; the detail area shows its info instead.
        guard entry.isDirectory else { return }

        if let cached = cache[entry.path] {
            selectedChildren = cached
            selectedMeasuredChildren = cached
            selectedPendingChildren = []
            return
        }

        // The measured flag catches TCC-denied folders (which stay POSIX-
        // readable); isReadableFile catches permission-locked ones.
        if entry.isUnreadable || !FileSystem.manager.isReadableFile(atPath: entry.path) {
            selectionUnreadable = true
            isMeasuringSelection = false
            return
        }
        selectionUnreadable = false
        isMeasuringSelection = true
        selectionGeneration += 1
        let generation = selectionGeneration
        selectionTask = Task { [weak self] in
            guard let self else { return }
            let stream = DiskAnalyzer.children(of: entry.path)
            for await event in stream {
                if Task.isCancelled { return }
                guard generation == self.selectionGeneration else { return }
                self.applySelection(event, path: entry.path)
            }
        }
    }

    private func applySelection(_ event: DiskEvent, path: String) {
        switch event {
        case .listed(let entries):
            selectionTotalCount = entries.count
            selectionMeasuredCount = 0
            selectionUnreadable = false
            selectedPendingChildren = entries.sorted { $0.name < $1.name }
            selectedChildren = selectedMeasuredChildren + selectedPendingChildren

        case .measured(let entry):
            selectionMeasuredCount += 1
            selectedPendingChildren.removeAll { $0.id == entry.id }
            insert(entry, into: &selectedMeasuredChildren)
            selectedChildren = selectedMeasuredChildren + selectedPendingChildren

        case .finished:
            isMeasuringSelection = false
            selectedPendingChildren = []
            selectedChildren = selectedMeasuredChildren
            storeInCache(path, selectedChildren)
        }
    }

    // MARK: Cache

    private func storeInCache(_ path: String, _ entries: [DiskEntry]) {
        if cache[path] == nil {
            cacheOrder.append(path)
            if cacheOrder.count > cacheCapacity {
                // Drop the oldest listing: the cache only exists to make
                // re-visits instant, and any listing can be re-measured.
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        cache[path] = entries
    }

    // MARK: Root entry

    private func rootEntry() -> DiskEntry {
        let name = (try? FileSystem.url(rootPath).resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        let title = (name?.isEmpty == false ? name! : nil) ?? L10n.tr("diskAnalysis.disk")
        return DiskEntry(
            id: rootPath,
            name: title,
            path: rootPath,
            isDirectory: true,
            size: volumeUsage.used,
            folderCount: 0,
            fileCount: 0,
            isMeasured: true,
            isUnreadable: false
        )
    }

    /// Breadcrumb entries for the path components between the root and `path`.
    /// Synthesized because a jump skips the intermediate levels: the
    /// breadcrumb renders names only, and entering any level measures it.
    private func synthesizedEntries(along path: String) -> [DiskEntry] {
        var entries: [DiskEntry] = []
        var current = rootPath
        let relative = String(path.dropFirst(rootPath.count))
        for component in relative.split(separator: "/") {
            current = current == "/" ? "/\(component)" : "\(current)/\(component)"
            entries.append(
                DiskEntry(
                    id: current,
                    name: String(component),
                    path: current,
                    isDirectory: true,
                    size: 0,
                    folderCount: 0,
                    fileCount: 0,
                    isMeasured: true,
                    isUnreadable: false
                )
            )
        }
        return entries
    }

    // MARK: Test seam

    /// Waits until both measurements go quiet. Both flags are set
    /// synchronously by the action that starts the work, so polling them
    /// right after an action never misses it.
    func waitUntilSettled() async {
        while isMeasuring || isMeasuringSelection {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
