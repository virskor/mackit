import Foundation
import AppKit

/// State model for the duplicate-file tool page.
///
/// The page answers "which files exist more than once": walk one directory
/// tree, group files with byte-identical content, and let the user move the
/// redundant copies to the Trash through the same `CleanEngine` the cleanup
/// scan uses.
///
/// The scan is deliberately not started on arrival — a home-directory
/// traversal plus content comparison is minutes of IO the user did not ask
/// for, so the first visit leaves the start screen up for the button, the
/// same contract the large-file page has. A later scan replaces the groups
/// rather than filtering them: the threshold is applied during enumeration,
/// so a lower threshold cannot be recovered from an existing list.
///
/// Groups stream in as comparison proves them. Proven groups do not change
/// after emission — the digests are the verdict — so showing one the moment
/// it lands shows nothing that is still moving. What still waits for the
/// end is the order: the engine emits groups as its buckets complete, and
/// the list is re-ordered by reclaimable bytes when the scan lands.
///
/// Nothing arrives checked. A cleaner that pre-ticks deletions is one
/// careless click away from removing files the user never looked at, so the
/// page never checks a row on the user's behalf: the "keep" badge marks the
/// copy the tool suggests holding on to (see `isKept`), and every check —
/// and therefore every deletion — is the user's own act, with the
/// confirmation sheet as the last gate.
///
/// The scanned groups survive page switches like the other tools' (the scan
/// belongs to the session, not to the page being visible), and a rescan or a
/// setting change is the only thing that re-walks.
@MainActor
@Observable
final class DuplicatesModel {
    /// The size presets the threshold picker offers. Decimal units, because
    /// that is what Finder's Get Info prints — the same reasoning as the
    /// large-file presets. The floor is deliberately low: duplicate
    /// documents and photos are far smaller than the files the large-file
    /// tool lists, and the content comparison only ever reads multi-file
    /// buckets, so the threshold trades coverage against scan time, not
    /// correctness.
    enum Threshold: Int64, CaseIterable, Identifiable {
        case kb200 = 200_000
        case mb1 = 1_000_000
        case mb10 = 10_000_000
        case mb100 = 100_000_000

        var id: Int64 { rawValue }

        var label: String { Formatters.bytes(rawValue) }
    }

    /// Which pass of the scan is running: the directory walk, then the
    /// content comparison over the candidates it retained.
    enum ScanStage {
        case walking
        case comparing
    }

    /// The page's state machine. Kept private to the model so the sheet, the
    /// overlay and the result card are all driven from one place — the same
    /// shape the other tools use.
    enum Phase: Equatable {
        case idle
        case confirming
        case cleaning
        case done
    }

    // MARK: Scan state

    private(set) var isScanning = false
    /// Which pass of the in-flight scan is running, for the scan strip's
    /// second line.
    private(set) var scanStage: ScanStage = .walking
    /// The directory being walked / the file being compared right now.
    private(set) var scanCurrentPath = ""
    /// Directories visited so far. The walk's total is unknowable up front,
    /// so this is a count, not a fraction.
    private(set) var scannedDirectories = 0
    /// Bytes of content compared so far against the budget below.
    private(set) var comparedBytes: Int64 = 0
    /// Total bytes the comparison stage still has to read.
    private(set) var totalCompareBytes: Int64 = 0
    /// How long the in-flight scan has been running, republished by a timer
    /// so the readout keeps moving between progress events (which are
    /// throttled and can stop entirely while one huge directory is being
    /// enumerated or one large file read).
    private(set) var scanElapsed: Duration = .zero
    /// Whether the last scan ran to completion. A stopped scan keeps
    /// whatever it already found — the page says the list is partial rather
    /// than passing it off as everything there is.
    private(set) var scanCompleted = false
    /// Whether a scan has landed at least once. A threshold or
    /// protected-folder change re-scans when there is a finished scan or a
    /// stopped one that left groups on screen; before either, the new value
    /// is simply what the first scan uses.
    private(set) var hasScanned = false
    /// Directories the scan could not read at all (a denied TCC prompt, a
    /// locked folder). Non-zero means the scan may have missed files. The
    /// page's notice about that is suppressed when Full Disk Access is
    /// already granted — see `fullDiskAccessGranted`.
    private(set) var unreadableDirectories = 0
    /// Candidates excluded for having several names (hard links): deleting
    /// one name of such a file frees nothing, so they are never offered as
    /// reclaimable duplicates. Surfaced as an informational notice, not an
    /// error.
    private(set) var skippedLinkedFiles = 0
    /// Whether Full Disk Access is currently granted, probed when a scan
    /// lands. The unreadable-folders notice is gated on it: a folder the
    /// scan still could not read with the grant in place is one the grant
    /// cannot help (a system-protected or locked location), so the notice —
    /// whose offer is the grant — would only send the user to a permission
    /// they already have.
    private(set) var fullDiskAccessGranted = false

    /// Every proven group, in the order the comparison emitted it. The
    /// comparison's buckets finish concurrently, so that order is not final
    /// until the scan lands; the presentation order is applied there (see
    /// `visibleGroups`).
    private(set) var groups: [DuplicateGroup] = []

    /// Each file path → the path its group suggests keeping. Decided once
    /// when the group lands and refreshed where membership changes; the
    /// badge is rendered on every visible row every frame, and deciding it
    /// per render is a linear search over every group for every row — this
    /// lookup is what keeps a scroll frame O(visible rows).
    private var keptByPath: [String: String] = [:]

    /// The size threshold, applied during the walk. Private so the only way
    /// to change it is `setThreshold`, which re-runs a scan whose groups
    /// were collected under the old value.
    private(set) var threshold: Threshold = .mb1

    /// Whether the scan enters the TCC-protected home trio (Documents /
    /// Desktop / Downloads). Off by default: entering one pops the system
    /// access dialog, so it stays an explicit opt-in rather than something a
    /// scan stumbles into. Changed through `setIncludeProtectedPaths`, for
    /// the same re-scan reason as the threshold.
    private(set) var includeProtectedPaths = false

    /// Filter over the found files' names and paths; a group stays visible
    /// whole if any of its members matches.
    var searchText: String = ""

    /// Paths the user has checked for the Trash action. Nothing is ever
    /// checked automatically; a rescan keeps the checks whose files the new
    /// scan found again and drops the ghosts (see `applyFinished`).
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

    /// Searches `root` for duplicate files at or above `threshold` bytes.
    /// Runs off the main thread inside its default implementation — a
    /// traversal plus content comparison is minutes of IO.
    private let scan: @Sendable (String, Set<String>, Int64) -> AsyncStream<DuplicateFileScanEvent>
    /// Removes the given items, reporting each outcome.
    private let clean: @MainActor @Sendable ([JunkItem], Bool) -> AsyncStream<CleanEvent>
    /// Whether Full Disk Access is currently granted. A seam like the
    /// others: the real probe is a few directory opens, and pinning it lets
    /// a test decide the unreadable-folders notice's answer without
    /// depending on the machine running the suite.
    private let fullDiskAccess: @MainActor @Sendable () -> Bool

    private let rootPath: String

    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    /// Ticks `scanElapsed` while a scan runs.
    private var elapsedTimer: Task<Void, Never>?
    /// When the in-flight scan started.
    private var scanStartedAt: ContinuousClock.Instant?
    /// Generation counter for the event stream. Starting a scan cancels the
    /// in-flight one, but cancellation is cooperative — a task sitting
    /// between two events can still deliver one more. Tagging each scan with
    /// a generation and dropping stale events keeps a cancelled scan's
    /// leftovers out of the new results.
    private var scanGeneration = 0

    /// File paths pending removal. One is recorded for each successful clean,
    /// and all are dropped from the list in one batch at the end — the same
    /// batching the cleanup scan uses, for the same reason: removing them one
    /// by one is O(n) per item.
    private var pendingRemoval: Set<String> = []
    /// Clean-engine item id → file path, for the running clean's targets. The
    /// engine reports outcomes against `JunkItem.id` (`ruleID::path`), and
    /// the list is keyed by path; this is the one place the two spellings
    /// meet.
    private var itemIDToPath: [String: String] = [:]

    /// When the running clean started; its duration is logged on finish.
    private var cleanStartedAt: ContinuousClock.Instant?

    /// The file-icon cache. Excluded from Observation: filling it during a
    /// render would add a pointless extra round of body recomputation.
    @ObservationIgnored private let iconCache: FileIconCache

    init(
        rootPath: String = NSHomeDirectory(),
        scan: @escaping @Sendable (String, Set<String>, Int64) -> AsyncStream<DuplicateFileScanEvent> = { root, protected, threshold in
            DuplicateFileScanner.scan(root: root, protectedPaths: protected, threshold: threshold)
        },
        clean: @escaping @MainActor @Sendable ([JunkItem], Bool) -> AsyncStream<CleanEvent> = { items, moveToTrash in
            CleanEngine.clean(items: items, moveToTrash: moveToTrash)
        },
        fullDiskAccess: @escaping @MainActor @Sendable () -> Bool = {
            AppPermissions.fullDiskAccess() == .granted
        },
        iconForPath: @escaping @MainActor @Sendable (String) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0) }
    ) {
        self.rootPath = rootPath
        self.scan = scan
        self.clean = clean
        self.fullDiskAccess = fullDiskAccess
        self.iconCache = FileIconCache(load: iconForPath)
    }

    // MARK: Lifecycle

    /// Called when the sidebar selects the tool. Never starts a scan: a
    /// finished list restores instantly, so coming back is free, and a first
    /// visit leaves the start screen up for the user to press. An in-flight
    /// scan is likewise left alone — it belongs to the session, not to the
    /// page being visible, and cancelling it on every sidebar click would
    /// throw away minutes of IO.
    func activate() {
        // Nothing to resume: a finished scan's results are already here and
        // a running one keeps its flags. Kept as the hook the other tools'
        // models share, so the view model's call site stays uniform.
    }

    // MARK: Scan actions

    /// The start screen's button, and what the toolbar's rescan does while
    /// nothing has been scanned yet. The list is dropped — content anywhere
    /// may have changed since the last scan, and keeping stale groups would
    /// offer paths that no longer hold what was compared.
    func startScan() {
        startScan(at: rootPath)
    }

    /// The toolbar button: stops an in-flight scan, otherwise starts a fresh
    /// one.
    func rescanOrStop() {
        if isScanning {
            cancelScan()
            return
        }
        startScan()
    }

    /// Stops the in-flight scan. The page keeps whatever the scan already
    /// found, flagged as partial (see `scanCompleted`).
    ///
    /// The scanning strip's cancel and the toolbar's rescan/stop are the
    /// user paths; a new scan also cancels the old task, but it does so
    /// directly because it immediately replaces the old generation. Leaving
    /// the page does not cancel: the scan is the model's, and cancelling it
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

    /// Sets the threshold. Changing it on top of a finished scan, or a
    /// stopped one that left groups on screen, re-runs the scan: the
    /// threshold is applied during enumeration, so a narrower one cannot be
    /// recovered by filtering an existing list. Mid-scan the value is
    /// recorded but takes effect on the next scan — the picker is disabled
    /// while one runs, and restarting a minutes-long scan because the user
    /// touched a disabled-looking control would be its own bug.
    func setThreshold(_ preset: Threshold) {
        guard preset != threshold else { return }
        guard phase != .cleaning else { return }
        threshold = preset
        // A finished scan is the usual case, but a stopped first scan can
        // have left proven groups on screen while `hasScanned` is still
        // false. Those groups were collected under the old threshold, so a
        // new value has to re-run rather than relabel them.
        if !isScanning, hasScanned || !groups.isEmpty {
            startScan()
        }
    }

    /// Sets whether the scan enters the TCC-protected home trio. Same
    /// re-scan contract as the threshold: the protected set is baked into a
    /// scan while it runs, so an existing finished or partial list is
    /// rebuilt under the new value.
    func setIncludeProtectedPaths(_ included: Bool) {
        guard included != includeProtectedPaths else { return }
        guard phase != .cleaning else { return }
        includeProtectedPaths = included
        if !isScanning, hasScanned || !groups.isEmpty {
            startScan()
        }
    }

    // MARK: Selection

    func isSelected(_ file: DuplicateFile) -> Bool {
        selectedPaths.contains(file.path)
    }

    /// Checks or unchecks one file.
    func setSelected(_ file: DuplicateFile, selected: Bool) {
        if selected {
            selectedPaths.insert(file.path)
        } else {
            selectedPaths.remove(file.path)
        }
    }

    /// The copy of `group` this tool suggests keeping: the oldest
    /// modification date, because a copy made later is the derivative one.
    /// Ties fall to the shorter path — the more canonical location — and a
    /// file whose date the filesystem would not say is never treated as the
    /// oldest: "unknown" is not "original". When no member has a date, the
    /// path rule decides alone. A suggestion only — it drives the "keep"
    /// badge, never the selection.
    static func keptPath(in group: DuplicateGroup) -> String? {
        guard let first = group.files.first else { return nil }
        let dated = group.files.filter { $0.modified != nil }
        let pool = dated.isEmpty ? group.files : dated
        return pool.min { lhs, rhs in
            let l = lhs.modified ?? .distantFuture
            let r = rhs.modified ?? .distantFuture
            if l != r { return l < r }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }?.path ?? first.path
    }

    /// Whether `file` is the copy this tool suggests keeping. A lookup: the
    /// suggestion is re-decided only where the list changes (`keptByPath`),
    /// never per row per render.
    func isKept(_ file: DuplicateFile) -> Bool {
        keptByPath[file.path] == file.path
    }

    /// Shows the file in Finder — its enclosing folder, the way the other
    /// tools reveal a file: the file itself is never handed to whatever
    /// application claims it (see `RevealInFinder`).
    func revealInFinder(_ file: DuplicateFile) {
        RevealInFinder.show(file: URL(fileURLWithPath: file.path))
    }

    // MARK: Derived data

    /// The groups the search field leaves, in the list's current order:
    /// emission order while a scan is still appending, then reclaimable
    /// bytes first once it lands.
    ///
    /// Computed rather than stored: the list holds at most a few hundred
    /// groups, so filtering per read is cheaper than cache-invalidation
    /// machinery — and it keeps working while the scan is still appending.
    var visibleGroups: [DuplicateGroup] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.filter { group in
            group.files.contains {
                $0.name.lowercased().contains(needle) || $0.path.lowercased().contains(needle)
            }
        }
    }

    private var allFiles: [DuplicateFile] {
        groups.flatMap(\.files)
    }

    /// The checked files, in list order — scoped to the groups the search
    /// field leaves, the same contract the large-file page's selection has.
    /// The confirmation sheet lists exactly this, so a deletion can never
    /// include a file the user filtered away and cannot see; clearing the
    /// filter brings the full selection back, because `selectedPaths` itself
    /// is never touched by the filter.
    var selectedFiles: [DuplicateFile] {
        visibleGroups.flatMap(\.files).filter { selectedPaths.contains($0.path) }
    }

    var selectedSize: Int64 {
        selectedFiles.reduce(0) { $0 + $1.size }
    }

    /// The file count across every group — the header's summary line.
    var totalFiles: Int {
        groups.reduce(0) { $0 + $1.files.count }
    }

    /// The bytes the redundant copies are allocated — the header's
    /// reclaimable figure. Each group contributes its total minus its
    /// largest copy, so a sparse duplicate cannot make the figure promise
    /// bytes that trashing it would not free. An APFS clone shares blocks
    /// physically, so this remains an estimate; the clean result card
    /// reports what each removal actually returned.
    var totalWasted: Int64 {
        groups.reduce(0) { $0 + $1.wasted }
    }

    /// How many groups would lose *every* copy to the current selection.
    /// Moving all copies of a group out does not lose content while it sits
    /// in the Trash, but with the permanent-delete setting it does — the
    /// confirmation sheet counts those groups rather than staying silent.
    ///
    /// Scoped to the same visible list `selectedFiles` is: the sheet deletes
    /// exactly those files, so a group hidden by the search filter cannot be
    /// part of this answer. Counting it would warn about content loss that
    /// the confirm button will not cause.
    var groupsFullySelected: Int {
        visibleGroups.filter { group in
            group.files.allSatisfy { selectedPaths.contains($0.path) }
        }.count
    }

    // MARK: Icons

    /// File icons, cached per path: `NSWorkspace.icon` is not free, and the
    /// list re-renders on every observation change.
    func icon(forPath path: String) -> NSImage {
        iconCache.icon(forPath: path)
    }

    // MARK: Scan

    private func startScan(at path: String) {
        // The result card and the confirmation sheet both describe the old
        // list; a scan rebuilds that list, so either one is dismissed rather
        // than promising a result for files it no longer covers. Refusing to
        // start under a running clean is the caller's guard — the header
        // disables its rescan button then — but it is repeated here so a
        // programmatic threshold change cannot orphan an in-flight clean.
        guard phase != .cleaning else { return }
        if phase != .idle { phase = .idle }
        scanStartCount += 1
        scanTask?.cancel()
        isScanning = true
        scanStage = .walking
        scanCurrentPath = path
        scannedDirectories = 0
        comparedBytes = 0
        totalCompareBytes = 0
        scanElapsed = .zero
        scanStartedAt = .now
        scanCompleted = false
        unreadableDirectories = 0
        skippedLinkedFiles = 0
        groups = []
        keptByPath = [:]
        // The user's checks are not reset: like the large-file walk, a
        // rescan keeps whatever checks still name real files (pruned at
        // `applyFinished`) so a threshold change does not throw the user's
        // curation away.
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
                case .hashing(let compared, let total, let current):
                    self.applyHashing(compared: compared, total: total, current: current)
                case .found(let group):
                    self.applyFound(group)
                case .finished(let unreadable, let skipped):
                    self.applyFinished(unreadable: unreadable, skippedLinked: skipped)
                }
            }
            // The stream only ends after .finished, or after a cancel (which
            // already cleared the flag). The generation guard keeps a stale
            // task from clearing a newer scan's flag; the reset keeps a scan
            // from ever leaving the page stuck on the scanning screen.
            guard !Task.isCancelled, generation == self.scanGeneration else { return }
            self.isScanning = false
        }
    }

    private func applyHashing(compared: Int64, total: Int64, current: String) {
        scanStage = .comparing
        comparedBytes = compared
        totalCompareBytes = total
        scanCurrentPath = current
    }

    private func applyFound(_ group: DuplicateGroup) {
        // Deliberately no auto-selection: the group lands unchecked, and the
        // "keep" badge carries the suggestion instead. Pre-ticking deletions
        // on the user's behalf is the one mistake this page must never make.
        groups.append(group)
        // The suggestion is decided once, when the group lands: its
        // membership cannot change until a clean removes members.
        let kept = Self.keptPath(in: group)
        for file in group.files { keptByPath[file.path] = kept }
    }

    private func applyFinished(unreadable: Int, skippedLinked: Int) {
        isScanning = false
        stopElapsedTimer()
        hasScanned = true
        scanCompleted = true
        unreadableDirectories = unreadable
        skippedLinkedFiles = skippedLinked
        // The engine emits groups as its buckets complete, which during the
        // comparison runs concurrently; the presentation order is decided
        // once the scan lands: the most reclaimable bytes first.
        groups.sort { lhs, rhs in
            if lhs.wasted != rhs.wasted { return lhs.wasted > rhs.wasted }
            return (lhs.files.first?.path ?? "") < (rhs.files.first?.path ?? "")
        }
        // Probed here, where the notice the answer gates becomes relevant:
        // the grant state during the scan is the one that explains the
        // folders it could not read.
        fullDiskAccessGranted = fullDiskAccess()
        // A rescan re-walks the tree: a file that no longer exists (deleted
        // elsewhere) must not stay checked as a ghost. Files the scan found
        // again keep their checks, so a rescan does not throw away the
        // user's curation.
        selectedPaths.formIntersection(Set(allFiles.map(\.path)))
    }

    /// Keeps `scanElapsed` moving while a scan runs. The progress events are
    /// throttled and can pause entirely while one huge directory is being
    /// enumerated or one large file read, so without this the elapsed
    /// readout would freeze in jumps — exactly when the user is most likely
    /// staring at it.
    private func startElapsedTimer() {
        // Cancels the task inline rather than through `stopElapsedTimer`:
        // that also clears the start instant, which this scan just recorded.
        elapsedTimer?.cancel()
        elapsedTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                // A model dropped mid-scan has nobody left to cancel this
                // task: the only canceller is the model's own
                // `stopElapsedTimer`. The weak capture keeps it from
                // retaining the model, but without this guard the loop would
                // wake every 500 ms forever with nothing left to update.
                guard let self else { return }
                self.tickElapsed()
            }
        }
    }

    /// Publishes the in-flight scan's elapsed time. Called by the timer; a
    /// no-op once the scan it belongs to has stopped, so a late tick cannot
    /// resurrect a finished scan's clock. Visible within the module so the
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

    /// The folders this scan refuses to enter without an explicit request:
    /// the TCC-protected home trio, unless the user opted in. Entering one
    /// pops the system access dialog, so a scan skips them and the start
    /// screen carries the opt-in — the same trade the large-file walk makes,
    /// for the same reason.
    private var skipPaths: Set<String> {
        guard !includeProtectedPaths else { return [] }
        return FileSystem.protectedHomePaths(under: FileSystem.expand("~"))
    }

    // MARK: Trash flow

    /// Opens the confirmation sheet for the current selection.
    ///
    /// Refused while a scan runs: the list is still streaming, so the
    /// selection is a moving target — and deleting a file the scan is about
    /// to report again would re-add it to the list after the clean drops it,
    /// leaving a row for something that no longer exists. Wait for the scan
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
        MackitLog.clean.info("duplicate clean started: \(targets.count, privacy: .public) entries, \(targetSize, privacy: .public) bytes, move to Trash \(moveToTrash, privacy: .public)")

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
                MackitLog.clean.error("duplicate clean failed \"\(outcome.title, privacy: .public)\": \(outcome.message, privacy: .public)")
            }
            if let startedAt = cleanStartedAt {
                MackitLog.clean.info("duplicate clean finished: freed \(reclaimed, privacy: .public) bytes, \(failures, privacy: .public) failures, took \(MackitLog.duration(.now - startedAt), privacy: .public)")
                cleanStartedAt = nil
            }
            // Removed in one batch: the deleted files leave the list and the
            // result card takes the page's place.
            removeCleanedItems(pendingRemoval)
            pendingRemoval = []
        }
    }

    /// Drops the cleaned items from the list in one batch. A group left with
    /// a single file is no longer a duplicate and dissolves; a file that
    /// failed to delete stays listed — it is still on disk — and stays
    /// checked so it can be retried; only items that actually left the disk
    /// lose their check.
    private func removeCleanedItems(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        groups = groups.compactMap { group in
            // Only a group that lost members can change: untouched groups
            // pass through whole, their suggestion still valid.
            guard group.files.contains(where: { paths.contains($0.path) }) else { return group }
            // The old suggestion is void either way — its group is losing
            // members or dissolving — so the group's entries are cleared
            // wholesale before the survivors decide anew.
            for file in group.files { keptByPath.removeValue(forKey: file.path) }
            let remaining = group.files.filter { !paths.contains($0.path) }
            guard remaining.count > 1 else { return nil }
            // A removed keeper hands the badge to the next-oldest survivor.
            let kept = Self.keptPath(in: DuplicateGroup(id: group.id, files: remaining))
            for file in remaining { keptByPath[file.path] = kept }
            return DuplicateGroup(id: group.id, files: remaining)
        }
        // Drop checks whose file is no longer part of any group: a group
        // that dissolved leaves its survivor on disk but no longer a
        // duplicate, so keeping its check alive would only be an invisible
        // ghost until the next scan pruned it.
        selectedPaths.formIntersection(Set(allFiles.map(\.path)))
    }

    /// Stops the clean. Items that already left the disk are dropped from
    /// the list; the ones that failed — or were never attempted — stay
    /// checked for a retry.
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
            MackitLog.clean.info("duplicate clean cancelled by user: \(alreadyRemoved, privacy: .public) completed entries removed from the list")
        } else {
            MackitLog.clean.info("duplicate clean cancelled by user: no completed entries")
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

    /// A found file as a cleanable entry, for the shared clean engine and
    /// the confirmation sheet's list.
    ///
    /// Risk is `.review` across the board: a duplicate is content the user
    /// chose to keep at least one copy of, and the confirmation sheet says
    /// so rather than guessing per file. The vnode identity travels with the
    /// item, so the engine's changed-file re-check applies — a path that now
    /// names a different file than the one that was compared is refused.
    func junkItem(for file: DuplicateFile) -> JunkItem {
        JunkItem(
            ruleID: Self.cleanRuleID,
            title: file.name,
            detail: file.parentPath,
            path: file.path,
            category: .system,
            risk: .review,
            size: file.size,
            modified: file.modified,
            isDirectory: false,
            nodeIdentity: file.nodeIdentity
        )
    }

    /// The rule id a cleaned entry carries. Shared so the running clean can
    /// map the engine's outcome ids back to file paths.
    static let cleanRuleID = "duplicateFile"

    // MARK: Test seam

    /// How many scans this model has started.
    ///
    /// Several behaviors are "did *not* start another scan" — activation
    /// during a run, coming back to the page — and a count states that
    /// directly, instead of inferring it from whether results showed up
    /// (which a fast fixture makes indistinguishable from a restart).
    /// Observation is ignored: it is bookkeeping, not page state.
    @ObservationIgnored private(set) var scanStartCount = 0

    /// Test seam: waits until no scan or clean is in flight. Same polling
    /// contract as the other tools' models.
    func waitUntilSettled() async {
        while isScanning || phase == .cleaning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
