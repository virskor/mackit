import Foundation
import AppKit

/// State model for the large-file analysis tool page.
///
/// The page answers "what is taking up the disk, file by file": walk the
/// startup disk, list every file at or above a size threshold, and let the
/// user move the ones they no longer need to the Trash through the same
/// `CleanEngine` the cleanup scan uses.
///
/// The walk is deliberately not started on arrival — a whole-disk traversal
/// is minutes of IO the user did not ask for, so the first visit leaves the
/// start screen up for the button, the same contract the disk analysis page
/// has. Every later walk — a rescan, a threshold change — replaces the list
/// rather than filtering it, because the threshold is applied during
/// enumeration: only hits are retained, so a lower threshold cannot be
/// recovered from an existing list.
///
/// Hits stream in as the walk finds them. This is the one place the house
/// "no half-filled results" rule bends: the disk analysis withholds its tree
/// because directory totals are still moving, while a hit here is a finished
/// fact — the kernel's allocation for the file as it exists now — and a
/// minutes-long walk with an empty screen is worse than a list that grows.
/// What still waits for the end is the *sort*: the list is presented in
/// discovery order while the walk runs and re-ordered when it lands (see
/// `visibleFiles`).
///
/// The scanned list survives page switches like the other tools' (the walk
/// belongs to the session, not to the page being visible), and a rescan is
/// the only thing that re-walks.
@MainActor
@Observable
final class LargeFilesModel {
    /// The size presets the threshold picker offers. Decimal units, because
    /// that is what Finder's Get Info prints: a user who sees "1 GB" there
    /// expects the same file to pass a "1 GB" filter here.
    enum Threshold: Int64, CaseIterable, Identifiable {
        case mb500 = 500_000_000
        case gb1 = 1_000_000_000
        case gb5 = 5_000_000_000

        var id: Int64 { rawValue }

        var label: String { Formatters.bytes(rawValue) }
    }

    /// The order the results are listed in. Size descending is the tool's
    /// whole point, but a large-file list is also something the user reads to
    /// decide what to delete — "which of these do I recognize" (name) and
    /// "which of these is stale" (date) — so each dimension goes both ways.
    enum Sort: String, CaseIterable, Identifiable {
        case sizeDescending
        case sizeAscending
        case name
        case nameDescending
        case recentModified
        case earliestModified

        var id: String { rawValue }

        var title: String { L10n.tr("largeFiles.sort.\(rawValue)") }

        /// The comparator behind this order, total so the sort is
        /// deterministic: equal on the primary key falls back to name
        /// ascending, and a missing modification date sorts last in either
        /// direction — "unknown" is not "oldest" any more than it is
        /// "newest".
        var comparator: (LargeFile, LargeFile) -> Bool {
            switch self {
            case .sizeDescending:
                return { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
            case .sizeAscending:
                return { $0.size == $1.size ? $0.name < $1.name : $0.size < $1.size }
            case .name:
                return { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .nameDescending:
                return { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            case .recentModified:
                return { Self.byModified(lhs: $0, rhs: $1, ascending: false) }
            case .earliestModified:
                return { Self.byModified(lhs: $0, rhs: $1, ascending: true) }
            }
        }

        /// Newest first (`ascending: false`) or oldest first. A missing date
        /// maps to the far end of the timeline in both directions, so
        /// undated entries always land at the bottom of the list.
        private static func byModified(lhs: LargeFile, rhs: LargeFile, ascending: Bool) -> Bool {
            let missing: Date = ascending ? .distantFuture : .distantPast
            let l = lhs.modified ?? missing
            let r = rhs.modified ?? missing
            if l == r { return lhs.name < rhs.name }
            return ascending ? l < r : l > r
        }
    }

    /// The page's state machine. Kept private to the model so the sheet, the
    /// overlay and the result card are all driven from one place — the same
    /// shape the app uninstall tool uses.
    enum Phase: Equatable {
        case idle
        case confirming
        case cleaning
        case done
    }

    // MARK: Scan state

    private(set) var isScanning = false
    /// The directory being walked right now, for the scanning screen.
    private(set) var scanCurrentPath = ""
    /// Directories visited so far. A whole-disk walk's total is unknowable up
    /// front, so this is a count, not a fraction.
    private(set) var scannedDirectories = 0
    /// How long the in-flight walk has been running, republished by a timer
    /// so the readout keeps moving between progress events (which are
    /// throttled and can stop entirely while one huge directory is being
    /// enumerated).
    private(set) var scanElapsed: Duration = .zero
    /// Whether the last walk ran to completion. A stopped walk keeps whatever
    /// it already found — the page says the list is partial rather than
    /// passing it off as everything above the threshold.
    private(set) var scanCompleted = false
    /// Whether a walk has landed at least once. Threshold and protected-folder
    /// changes only re-walk on top of a finished one; before that there is
    /// nothing to redo and the new value is simply what the first walk uses.
    private(set) var hasScanned = false
    /// Directories the walk could not read at all (a denied TCC prompt, a
    /// locked folder). Non-zero means the scan may have missed files.
    private(set) var unreadableDirectories = 0

    /// Every hit, in discovery order. The presentation order lives in
    /// `visibleFiles` so the sort can change — and re-sort a list that is
    /// still growing — without rewriting this array.
    private(set) var files: [LargeFile] = []

    /// The size threshold, applied during the walk.
    var threshold: Threshold = .gb1

    /// Whether the walk enters the TCC-protected home trio (Documents /
    /// Desktop / Downloads). Off by default: entering one pops the system
    /// access dialog, so it stays an explicit opt-in rather than something a
    /// whole-disk walk stumbles into.
    var includeProtectedPaths = false

    /// The order results are listed in.
    var sort: Sort = .sizeDescending

    /// Filter over the hits' names and paths.
    var searchText: String = ""

    /// Paths the user has checked for the Trash action.
    var selectedPaths: Set<String> = []

    // MARK: Clean state

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var currentTitle: String = ""
    private(set) var outcomes: [CleanOutcome] = []
    /// How many of the reported outcomes succeeded. Failed items also went
    /// into `outcomes`; counting all of them would describe failures as
    /// "cleaned".
    private(set) var cleanedCount = 0
    private(set) var reclaimed: Int64 = 0
    private(set) var failures = 0
    /// Whether the finished clean moved anything to the Trash: those bytes
    /// are not back on the volume yet, so the result card says "moved out"
    /// rather than claiming them as released.
    private(set) var movedToTrash = false

    // MARK: Dependencies

    /// Walks `root`, reporting every file at or above `threshold` bytes.
    /// Runs off the main thread inside its default implementation — a
    /// whole-disk traversal is minutes of IO.
    private let scan: @Sendable (String, Set<String>, Int64) -> AsyncStream<LargeFileScanEvent>
    /// Removes the given items, reporting each outcome.
    private let clean: @MainActor @Sendable ([JunkItem], Bool) -> AsyncStream<CleanEvent>
    /// The real icon of a file path.
    private let iconForPath: @MainActor @Sendable (String) -> NSImage?

    private let rootPath: String

    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    /// Ticks `scanElapsed` while a walk runs.
    private var elapsedTimer: Task<Void, Never>?
    /// When the in-flight walk started.
    private var scanStartedAt: ContinuousClock.Instant?
    /// Generation counter for the event stream. Starting a walk cancels the
    /// in-flight one, but cancellation is cooperative — a task sitting
    /// between two events can still deliver one more. Tagging each walk with
    /// a generation and dropping stale events keeps a cancelled walk's
    /// leftovers out of the new results.
    private var scanGeneration = 0

    /// File paths pending removal. One is recorded for each successful clean,
    /// and all are dropped from the list in one batch at the end — the same
    /// batching the cleanup scan uses, for the same reason: removing them one
    /// by one is O(n) per item.
    private var pendingRemoval: Set<String> = []
    /// Clean-engine item id → file path, for the running clean's targets. The
    /// engine reports outcomes against `JunkItem.id` (`ruleID::path`), and the
    /// list is keyed by path; this is the one place the two spellings meet.
    private var itemIDToPath: [String: String] = [:]

    /// When the running clean started; its duration is logged on finish.
    private var cleanStartedAt: ContinuousClock.Instant?

    /// The file-icon cache. Excluded from Observation: filling it during a
    /// render would add a pointless extra round of body recomputation.
    /// Capped, with FIFO eviction — a walk can list thousands of paths and
    /// every cached NSImage carries its full representation set; eviction is
    /// cheap because an icon is a couple of syscalls to rebuild.
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var iconCacheOrder: [String] = []
    private let iconCacheCapacity = 128

    init(
        rootPath: String = "/",
        scan: @escaping @Sendable (String, Set<String>, Int64) -> AsyncStream<LargeFileScanEvent> = { root, protected, threshold in
            LargeFileScanner.scan(root: root, protectedPaths: protected, threshold: threshold)
        },
        clean: @escaping @MainActor @Sendable ([JunkItem], Bool) -> AsyncStream<CleanEvent> = { items, moveToTrash in
            CleanEngine.clean(items: items, moveToTrash: moveToTrash)
        },
        iconForPath: @escaping @MainActor @Sendable (String) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0) }
    ) {
        self.rootPath = rootPath
        self.scan = scan
        self.clean = clean
        self.iconForPath = iconForPath
    }

    // MARK: Lifecycle

    /// Called when the sidebar selects the tool. Never starts a walk: a
    /// finished list restores instantly, so coming back is free, and a first
    /// visit leaves the start screen up for the user to press. An in-flight
    /// walk is likewise left alone — it belongs to the session, not to the
    /// page being visible, and cancelling it on every sidebar click would
    /// throw away minutes of IO.
    func activate() {
        // Nothing to resume: a finished walk's results are already here and
        // a running one keeps its flags. Kept as the hook the other tools'
        // models share, so the view model's call site stays uniform.
    }

    // MARK: Scan actions

    /// The start screen's button, and what the toolbar's rescan does while
    /// nothing has been walked yet: a whole-disk walk from scratch. The list
    /// is dropped — sizes anywhere may have gone stale since the last walk,
    /// and keeping them would show numbers the user just asked to
    /// re-measure.
    func startScan() {
        startScan(at: rootPath)
    }

    /// The toolbar button: stops an in-flight walk, otherwise starts a fresh
    /// whole-disk one. A rescan drops the list — sizes anywhere may have gone
    /// stale since the last visit, and keeping them would show numbers the
    /// user just asked to re-measure.
    func rescanOrStop() {
        if isScanning {
            cancelScan()
            return
        }
        startScan()
    }

    /// Stops the in-flight walk. The page keeps whatever the walk already
    /// found, flagged as partial (see `scanCompleted`).
    ///
    /// Only the user's explicit stop reaches this (the scanning screen's
    /// cancel, the toolbar's rescan/stop, or a new walk replacing this one).
    /// Leaving the page does not: the walk is the model's, and cancelling it
    /// on every sidebar click threw away the work and left the tool looking
    /// reset.
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        stopElapsedTimer()
        // The task is gone, so the flag must go too — otherwise the page
        // would stay on the scanning screen with nothing to stop.
        isScanning = false
    }

    /// Sets the threshold. Changing it on top of a finished walk re-runs the
    /// walk: the threshold is applied during enumeration, so a narrower one
    /// cannot be recovered by filtering an existing list. Mid-walk the value
    /// is recorded but takes effect on the next walk — the picker is disabled
    /// while one runs, and restarting a minutes-long traversal because the
    /// user touched a disabled-looking control would be its own bug.
    func setThreshold(_ preset: Threshold) {
        guard preset != threshold else { return }
        guard phase != .cleaning else { return }
        threshold = preset
        if hasScanned, !isScanning {
            startScan()
        }
    }

    /// Sets whether the walk enters the TCC-protected home trio. Same
    /// re-walk contract as the threshold: the protected set is baked into a
    /// walk while it runs.
    func setIncludeProtectedPaths(_ included: Bool) {
        guard included != includeProtectedPaths else { return }
        guard phase != .cleaning else { return }
        includeProtectedPaths = included
        if hasScanned, !isScanning {
            startScan()
        }
    }

    // MARK: Selection

    func isSelected(_ file: LargeFile) -> Bool {
        selectedPaths.contains(file.path)
    }

    /// Checks or unchecks one file.
    func setSelected(_ file: LargeFile, selected: Bool) {
        if selected {
            selectedPaths.insert(file.path)
        } else {
            selectedPaths.remove(file.path)
        }
    }

    /// Shows the file in Finder — its enclosing folder, the way the disk
    /// analysis reveals a file: the file itself is never handed to whatever
    /// application claims it (see `RevealInFinder`).
    func revealInFinder(_ file: LargeFile) {
        RevealInFinder.show(file: URL(fileURLWithPath: file.path))
    }

    // MARK: Derived data

    /// The hits the search field leaves, in the current sort order.
    ///
    /// Computed rather than stored: the list holds at most a few hundred
    /// entries (a whole-disk walk above 500 MB finds tens), so filtering and
    /// sorting per read is cheaper than the cache-invalidation machinery a
    /// stored copy would need — and it keeps working while the walk is still
    /// appending hits.
    var visibleFiles: [LargeFile] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty
            ? files
            : files.filter { $0.name.lowercased().contains(needle) || $0.path.lowercased().contains(needle) }
        return matching.sorted(by: sort.comparator)
    }

    /// The checked files, in list order.
    var selectedFiles: [LargeFile] {
        visibleFiles.filter { selectedPaths.contains($0.path) }
    }

    var selectedSize: Int64 {
        selectedFiles.reduce(0) { $0 + $1.size }
    }

    /// The total size of every hit — the header's "N files · X" line.
    var totalSize: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    // MARK: Icons

    /// File icons, cached per path: `NSWorkspace.icon` is not free, and the
    /// list re-renders on every observation change.
    ///
    /// Capped: a walk can list thousands of paths, and each NSImage carries
    /// its full representation set. Eviction is FIFO — an icon is a few
    /// syscalls to rebuild, so the policy only has to be cheap.
    func icon(forPath path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = iconForPath(path) ?? NSWorkspace.shared.icon(forFile: path)
        if iconCacheOrder.count >= iconCacheCapacity {
            iconCache.removeValue(forKey: iconCacheOrder.removeFirst())
        }
        iconCacheOrder.append(path)
        iconCache[path] = icon
        return icon
    }

    // MARK: Walk

    private func startScan(at path: String) {
        // A walk rebuilds the list under any open confirmation sheet, so the
        // sheet is dismissed instead of promising one list while another is
        // being collected — the same contract the app uninstall tool's
        // rescan has.
        if phase == .confirming { phase = .idle }
        scanStartCount += 1
        scanTask?.cancel()
        isScanning = true
        scanCurrentPath = path
        scannedDirectories = 0
        scanElapsed = .zero
        scanStartedAt = .now
        scanCompleted = false
        unreadableDirectories = 0
        files = []
        startElapsedTimer()
        scanGeneration += 1
        let generation = scanGeneration
        let protectedPaths = skipPaths
        let threshold = self.threshold.rawValue
        scanTask = Task { [scan] in
            let stream = scan(path, protectedPaths, threshold)
            for await event in stream {
                if Task.isCancelled { return }
                guard generation == self.scanGeneration else { return }
                switch event {
                case .progress(let scanned, let current):
                    self.scannedDirectories = scanned
                    self.scanCurrentPath = current
                case .found(let file):
                    // Appended in discovery order: the walk is still running,
                    // so no order is final yet (see `visibleFiles`).
                    self.files.append(file)
                case .finished(let unreadable):
                    self.applyFinished(unreadable: unreadable)
                }
            }
            // The stream only ends after .finished, or after a cancel (which
            // already cleared the flag). The generation guard keeps a stale
            // task from clearing a newer walk's flag; the reset keeps a walk
            // from ever leaving the page stuck on the scanning screen.
            guard !Task.isCancelled, generation == self.scanGeneration else { return }
            self.isScanning = false
        }
    }

    private func applyFinished(unreadable: Int) {
        isScanning = false
        stopElapsedTimer()
        hasScanned = true
        scanCompleted = true
        unreadableDirectories = unreadable
        // A rescan re-walks the disk: a file that no longer exists (deleted
        // elsewhere) or no longer passes the threshold (the user lowered it)
        // must not stay checked as a ghost. Files the walk found again keep
        // their checks, so a rescan does not throw away the user's curation.
        selectedPaths.formIntersection(Set(files.map(\.path)))
    }

    /// Keeps `scanElapsed` moving while a walk runs. The progress events are
    /// throttled and can pause entirely while one huge directory is being
    /// enumerated, so without this the elapsed readout would freeze in jumps
    /// — exactly when the user is most likely staring at it.
    private func startElapsedTimer() {
        // Cancels the task inline rather than through `stopElapsedTimer`:
        // that also clears the start instant, which this walk just recorded.
        elapsedTimer?.cancel()
        elapsedTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                // A model dropped mid-walk has nobody left to cancel this
                // task: the only canceller is the model's own
                // `stopElapsedTimer`. The weak capture keeps it from
                // retaining the model, but without this guard the loop would
                // wake every 500 ms forever with nothing left to update.
                guard let self else { return }
                self.tickElapsed()
            }
        }
    }

    /// Publishes the in-flight walk's elapsed time. Called by the timer; a
    /// no-op once the walk it belongs to has stopped, so a late tick cannot
    /// resurrect a finished walk's clock. Visible within the module so the
    /// readout can be tested without waiting on real time.
    func tickElapsed() {
        guard let startedAt = scanStartedAt else { return }
        scanElapsed = .now - startedAt
    }

    private func stopElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
        scanStartedAt = nil
    }

    /// The folders this walk refuses to enter without an explicit request:
    /// the TCC-protected home trio, unless the user opted in. Entering one
    /// pops the system access dialog, so a whole-disk walk skips them and the
    /// start screen carries the opt-in — the same trade the disk analysis
    /// makes, for the same reason.
    private var skipPaths: Set<String> {
        guard !includeProtectedPaths else { return [] }
        return FileSystem.protectedHomePaths(under: FileSystem.expand("~"))
    }

    // MARK: Trash flow

    /// Opens the confirmation sheet for the current selection.
    ///
    /// Refused while a walk runs: the list is still streaming, so the
    /// selection is a moving target — and deleting a file the walk is about
    /// to report again would re-add it to the list after the clean drops it,
    /// leaving a row for something that no longer exists. Wait for the walk
    /// to land.
    func requestClean() {
        guard !selectedFiles.isEmpty, phase == .idle, !isScanning else { return }
        phase = .confirming
    }

    func cancelConfirmation() {
        guard phase == .confirming else { return }
        phase = .idle
    }

    /// Runs the clean over the selection. `moveToTrash` is the shared
    /// setting's current value, passed in per call so the tool never owns a
    /// second copy of it.
    func beginClean(moveToTrash: Bool) {
        guard phase == .confirming, !selectedFiles.isEmpty else { return }
        // A second clean replaces the first rather than racing it: two
        // engines deleting overlapping paths would report each other's
        // outcomes.
        cleanTask?.cancel()
        let targets = selectedFiles
        let targetSize = selectedSize
        let items = targets.map { junkItem(for: $0) }
        itemIDToPath = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), targets.map(\.path)))
        phase = .cleaning
        progress = 0
        outcomes = []
        cleanedCount = 0
        currentTitle = ""
        pendingRemoval = []
        cleanStartedAt = .now
        MackitLog.clean.info("large-file clean started: \(targets.count, privacy: .public) entries, \(targetSize, privacy: .public) bytes, move to Trash \(moveToTrash, privacy: .public)")

        cleanTask = Task { [clean] in
            let stream = clean(items, moveToTrash)
            for await event in stream {
                if Task.isCancelled { return }
                self.applyClean(event)
            }
        }
    }

    private func applyClean(_ event: CleanEvent) {
        switch event {
        case .started(let total):
            progress = total > 0 ? 0 : 1
            pendingRemoval = []
            currentTitle = L10n.tr("clean.preparing")

        case .progress(let completed, let total, let current):
            progress = total > 0 ? Double(completed) / Double(total) : 0
            currentTitle = current

        case .outcome(let outcome):
            outcomes.append(outcome)
            if outcome.succeeded {
                cleanedCount += 1
                if let path = itemIDToPath[outcome.itemID] {
                    pendingRemoval.insert(path)
                }
            }

        case .finished(let reclaimed, let failures):
            self.reclaimed = reclaimed
            self.failures = failures
            progress = 1
            phase = .done
            movedToTrash = outcomes.contains { $0.movedToTrash }
            for outcome in outcomes where !outcome.succeeded {
                MackitLog.clean.error("large-file clean failed \"\(outcome.title, privacy: .public)\": \(outcome.message, privacy: .public)")
            }
            if let startedAt = cleanStartedAt {
                MackitLog.clean.info("large-file clean finished: freed \(reclaimed, privacy: .public) bytes, \(failures, privacy: .public) failures, took \(MackitLog.duration(.now - startedAt), privacy: .public)")
                cleanStartedAt = nil
            }
            // Removed in one batch: the deleted files leave the list and the
            // result card takes the page's place.
            removeCleanedItems(pendingRemoval)
            pendingRemoval = []
        }
    }

    /// Drops the cleaned items from the list in one batch. A file that failed
    /// to delete stays listed — it is still on disk — and stays checked so it
    /// can be retried; only items that actually left the disk lose their
    /// check.
    private func removeCleanedItems(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        files = files.filter { !paths.contains($0.path) }
        selectedPaths.subtract(paths)
    }

    /// Stops the clean, keeping whatever it already removed in the list —
    /// the same contract the cleanup scan's cancel has.
    func cancelClean() {
        // Only a running clean can be cancelled: the stop button lives in
        // the cleaning overlay, and a stale call after the result card is up
        // would throw the finished result away.
        guard phase == .cleaning else { return }
        cleanTask?.cancel()
        cleanTask = nil
        if !pendingRemoval.isEmpty {
            let alreadyRemoved = pendingRemoval.count
            removeCleanedItems(pendingRemoval)
            pendingRemoval = []
            MackitLog.clean.info("large-file clean cancelled by user: \(alreadyRemoved, privacy: .public) completed entries removed from the list")
        } else {
            MackitLog.clean.info("large-file clean cancelled by user: no completed entries")
        }
        outcomes = []
        progress = 0
        cleanedCount = 0
        currentTitle = ""
        cleanStartedAt = nil
        phase = .idle
    }

    /// Leaves the result card for the list.
    func dismissResult() {
        guard phase == .done else { return }
        phase = .idle
    }

    /// A scanned file as a cleanable entry, for the shared clean engine and
    /// the confirmation sheet's list.
    ///
    /// Risk is `.review` across the board: a 2 GB file is as likely to be a
    /// VM image or a database as it is to be a stale download, so the
    /// confirmation sheet says "may hold your data" for every row rather
    /// than guessing per file. The engine's own `isProtected` refusal is the
    /// safety net for system paths.
    func junkItem(for file: LargeFile) -> JunkItem {
        JunkItem(
            ruleID: Self.cleanRuleID,
            title: file.name,
            detail: file.parentPath,
            path: file.path,
            category: .system,
            risk: .review,
            size: file.size,
            modified: file.modified,
            isDirectory: false
        )
    }

    /// The rule id a cleaned entry carries. Shared so the running clean can
    /// map the engine's outcome ids back to file paths.
    static let cleanRuleID = "largeFile"

    // MARK: Test seam

    /// How many walks this model has started.
    ///
    /// Several behaviors are "did *not* start another walk" — activation
    /// during a run, coming back to the page — and a count states that
    /// directly, instead of inferring it from whether results showed up
    /// (which a fast fixture makes indistinguishable from a restart).
    /// Observation is ignored: it is bookkeeping, not page state.
    @ObservationIgnored private(set) var scanStartCount = 0

    /// Test seam: waits until no walk or clean is in flight. Same polling
    /// contract as the other tools' models.
    func waitUntilSettled() async {
        while isScanning || phase == .cleaning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
