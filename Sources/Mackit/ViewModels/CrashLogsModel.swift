import AppKit
import Foundation

/// State model for the crash log list the settings page shows.
///
/// The list is read from the records directory on demand — when the settings
/// page appears, and again after anything that could have changed it — rather
/// than watched: a record is written by a process that is dying, so the only
/// writers are this process's own deletes and the next launch's prune.
///
/// Every dependency is injectable, the same contract the tool models have:
/// the settings section lists whatever store this model is built with, so
/// tests drive it against fixture records instead of the developer's own
/// Application Support folder.
@MainActor
@Observable
final class CrashLogsModel {
    /// The records, newest first.
    private(set) var entries: [CrashLogEntry] = []

    /// The record the detail sheet shows; nil closes it.
    var selectedEntry: CrashLogEntry?

    /// Symbolication results, cached per record. Symbolizing costs a
    /// subprocess for an answer that cannot change — the record and the
    /// binary it names are both immutable — so a second tap on the same
    /// record shows the cached result.
    private(set) var symbolications: [String: SymbolicationResult] = [:]

    /// Whether a symbolication is running, so the sheet can show progress
    /// on the one action that actually takes time.
    private(set) var isSymbolicating = false

    /// The last failure the view should surface as a toast. Cleared when the
    /// next action starts.
    private(set) var lastError: String?

    private let directory: URL
    private let loadEntries: @Sendable (URL) -> [CrashLogEntry]
    private let removeEntry: @MainActor @Sendable (URL, Bool) async -> CleanEngine.RemovalResult
    private let symbolicateEntry: @Sendable (CrashLogEntry) async -> SymbolicationResult
    private let revealEntry: @MainActor @Sendable (URL) -> Void

    init(
        directory: URL = CrashLogStore.directory,
        loadEntries: @escaping @Sendable (URL) -> [CrashLogEntry] = { CrashLogStore.entries(in: $0) },
        removeEntry: @escaping @MainActor @Sendable (URL, Bool) async -> CleanEngine.RemovalResult = { url, moveToTrash in
            await CleanEngine.removeFromDisk(url, moveToTrash: moveToTrash)
        },
        symbolicateEntry: @escaping @Sendable (CrashLogEntry) async -> SymbolicationResult = { entry in
            await Symbolicator.symbolicate(entry)
        },
        revealEntry: @escaping @MainActor @Sendable (URL) -> Void = { url in
            RevealInFinder.show(file: url)
        }
    ) {
        self.directory = directory
        self.loadEntries = loadEntries
        self.removeEntry = removeEntry
        self.symbolicateEntry = symbolicateEntry
        self.revealEntry = revealEntry
    }

    // MARK: - Reading

    /// Re-reads the records directory.
    func reload() {
        lastError = nil
        entries = loadEntries(directory)
    }

    // MARK: - Actions

    /// Opens (or closes) the detail sheet for one record.
    func select(_ entry: CrashLogEntry?) {
        selectedEntry = entry
    }

    /// Shows the record's file in Finder.
    func revealInFinder(_ entry: CrashLogEntry) {
        revealEntry(entry.fileURL)
    }

    /// Deletes one record through the shared removal funnel — the protected
    /// path check and the user's move-to-Trash preference both apply, exactly
    /// as they do to every other file the app removes.
    ///
    /// A failure leaves the entry listed: it is still on disk, and dropping
    /// the row would claim otherwise.
    func delete(_ entry: CrashLogEntry, moveToTrash: Bool) async {
        lastError = nil
        let result = await removeEntry(entry.fileURL, moveToTrash)
        switch result {
        case .trashed, .deleted:
            entries.removeAll { $0.id == entry.id }
            symbolications.removeValue(forKey: entry.id)
            if selectedEntry?.id == entry.id {
                selectedEntry = nil
            }
        case .failed(let message):
            lastError = message
        }
    }

    /// Deletes every record. Stops at nothing: one failure keeps that entry
    /// in the list (it is still on disk) and the rest still go.
    func deleteAll(moveToTrash: Bool) async {
        lastError = nil
        var removedIDs = Set<String>()
        var failures = 0
        for entry in entries {
            if case .failed = await removeEntry(entry.fileURL, moveToTrash) {
                failures += 1
            } else {
                removedIDs.insert(entry.id)
            }
        }
        entries.removeAll { removedIDs.contains($0.id) }
        symbolications = symbolications.filter { !removedIDs.contains($0.key) }
        if selectedEntry.map({ removedIDs.contains($0.id) }) == true {
            selectedEntry = nil
        }
        if failures > 0 {
            // `fmt`, not `tr`: the count is a placeholder in both forms, and
            // a raw `%lld` in a toast is the bug the plural keys' shared
            // layout exists to prevent.
            lastError = L10n.fmt(
                failures == 1
                    ? "settings.crashLogs.deleteAllFailed.one"
                    : "settings.crashLogs.deleteAllFailed.other",
                failures
            )
        }
    }

    /// Copies the record file to `destination`.
    ///
    /// The save panel is the view's job — this is only the file operation,
    /// so it is testable without one. It goes through the shared atomic
    /// write rather than remove-then-copy: the panel has already asked the
    /// user about replacing, and a copy that fails halfway must not leave
    /// the chosen destination empty. Failures are thrown rather than
    /// stored: the caller toasts them, and a stored `lastError` would
    /// surface the same failure twice.
    func export(_ entry: CrashLogEntry, to destination: URL) throws {
        let data = try Data(contentsOf: entry.fileURL)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try SharedStore.writeAtomically(data, to: destination, via: temporary)
    }

    /// Symbolicates one record, caching the result.
    func symbolicate(_ entry: CrashLogEntry) async {
        guard symbolications[entry.id] == nil, !isSymbolicating else { return }
        lastError = nil
        isSymbolicating = true
        defer { isSymbolicating = false }
        symbolications[entry.id] = await symbolicateEntry(entry)
    }
}
