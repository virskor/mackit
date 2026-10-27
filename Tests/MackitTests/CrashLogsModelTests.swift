import Foundation
import Testing

@testable import Mackit

/// Tests for the crash log list's state model.
///
/// The model is driven through its injected closures: a fixture store, a
/// recording removal, a canned symbolication — nothing touches the real
/// Application Support folder. What is pinned is the settings section's
/// contract: the list is what the store says it is, a failed delete keeps
/// its entry listed (it is still on disk), delete-all keeps its failures,
/// and symbolication is cached per record because it costs a subprocess.
@MainActor
struct CrashLogsModelTests {
    private func tempDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-crashlogs-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fixture record. Nonisolated so the model's `@Sendable` seams can
    /// build fixtures without hopping to the main actor. `directory` is
    /// where the record's file lives: the export tests write a real file
    /// there, and a fixture pointing anywhere else would have the model
    /// copy from a path that was never populated.
    nonisolated static func entry(
        _ id: String, epoch: Int64 = 100, in directory: URL? = nil
    ) -> CrashLogEntry {
        let base = directory ?? FileManager.default.temporaryDirectory
        return CrashLogEntry(
            id: id,
            fileURL: base.appendingPathComponent(id),
            date: Date(timeIntervalSince1970: Double(epoch)),
            pid: 1,
            isAgent: false,
            appVersion: "1.0.10",
            build: "1",
            osVersion: "Version 15.0.1",
            executablePath: "/Applications/Mackit.app/Contents/MacOS/Mackit",
            signal: 11,
            signalName: "SIGSEGV",
            faultAddress: nil,
            frames: [0x1000],
            imageHeader: 0x1000,
            imageEnd: 0x3000,
            exceptionName: nil,
            exceptionReason: nil
        )
    }

    /// What the load seam was asked to read.
    private final class LoadCall: @unchecked Sendable {
        var urls: [URL] = []
    }

    /// What a removal seam was asked to do.
    private final class RemovalCall: @unchecked Sendable {
        var urls: [URL] = []
        var moveToTrash: [Bool] = []
    }

    /// How many times the symbolication seam ran.
    private final class SymbolicationCount: @unchecked Sendable {
        var runs = 0
    }

    @Test
    func reloadLoadsThroughTheInjectedStore() {
        let directory = tempDirectory("reload")
        defer { try? FileManager.default.removeItem(at: directory) }
        let load = LoadCall()
        let model = CrashLogsModel(
            directory: directory,
            loadEntries: { url in
                load.urls.append(url)
                return [
                    Self.entry("crash-200-1-11.txt", epoch: 200),
                    Self.entry("crash-100-1-11.txt"),
                ]
            }
        )

        model.reload()

        #expect(load.urls == [directory])
        #expect(model.entries.map(\.id) == ["crash-200-1-11.txt", "crash-100-1-11.txt"])
    }

    @Test
    func deleteRemovesTheEntryAndClearsTheSelection() async {
        let directory = tempDirectory("delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = Self.entry("crash-100-1-11.txt")
        let other = Self.entry("crash-200-1-11.txt", epoch: 200)
        let call = RemovalCall()
        let model = CrashLogsModel(
            directory: directory,
            loadEntries: { _ in [target, other] },
            removeEntry: { url, moveToTrash in
                call.urls.append(url)
                call.moveToTrash.append(moveToTrash)
                return .deleted
            }
        )
        model.reload()
        model.select(target)
        // Symbolicate first so the cache has an entry to clear.
        await model.symbolicate(target)

        await model.delete(target, moveToTrash: false)

        #expect(model.entries.map(\.id) == ["crash-200-1-11.txt"])
        #expect(model.selectedEntry == nil)
        #expect(model.symbolications["crash-100-1-11.txt"] == nil)
        #expect(call.urls == [target.fileURL])
        #expect(call.moveToTrash == [false])
    }

    /// The user's move-to-Trash preference is passed through: a crash record
    /// leaves the disk the same way every other file does.
    @Test
    func deleteHonorsTheMoveToTrashPreference() async {
        let directory = tempDirectory("trash")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = Self.entry("crash-100-1-11.txt")
        let call = RemovalCall()
        let model = CrashLogsModel(
            directory: directory,
            loadEntries: { _ in [target] },
            removeEntry: { url, moveToTrash in
                call.moveToTrash.append(moveToTrash)
                return .trashed
            }
        )
        model.reload()

        await model.delete(target, moveToTrash: true)

        #expect(call.moveToTrash == [true])
        #expect(model.entries.isEmpty)
    }

    /// A failed removal leaves the entry listed: it is still on disk, and
    /// dropping the row would claim otherwise. The message the engine
    /// produced is what the view toasts.
    @Test
    func deleteFailureKeepsTheEntryListed() async {
        let directory = tempDirectory("delete-failed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = Self.entry("crash-100-1-11.txt")
        let model = CrashLogsModel(
            directory: directory,
            loadEntries: { _ in [target] },
            removeEntry: { _, _ in .failed("clean.error.trashFailed") }
        )
        model.reload()
        model.select(target)

        await model.delete(target, moveToTrash: true)

        #expect(model.entries.map(\.id) == ["crash-100-1-11.txt"])
        #expect(model.selectedEntry?.id == "crash-100-1-11.txt")
        #expect(model.lastError == "clean.error.trashFailed")
    }

    /// The success path of delete-all: every entry goes, the selection and
    /// the symbolication cache go with them, and no error is stored for the
    /// toast to surface.
    @Test
    func deleteAllRemovesEveryEntryWhenNothingFails() async {
        let directory = tempDirectory("delete-all-clean")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Self.entry("crash-100-1-11.txt")
        let second = Self.entry("crash-200-1-11.txt", epoch: 200)
        let model = CrashLogsModel(
            directory: directory,
            loadEntries: { _ in [first, second] },
            removeEntry: { _, _ in .deleted },
            symbolicateEntry: { entry in
                SymbolicationResult(
                    frames: entry.frames.map { SymbolizedFrame(address: $0, symbol: "main") },
                    unavailableReason: nil
                )
            }
        )
        model.reload()
        model.select(first)
        await model.symbolicate(first)

        await model.deleteAll(moveToTrash: false)

        #expect(model.entries.isEmpty)
        #expect(model.selectedEntry == nil)
        #expect(model.symbolications.isEmpty)
        #expect(model.lastError == nil)
    }

    /// One failure does not stop the rest, and the count of failures is
    /// reported in the singular or the plural by the count itself.
    @Test
    func deleteAllKeepsFailuresAndReportsThem() async {
        let directory = tempDirectory("delete-all")
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = Self.entry("crash-100-1-11.txt")
        let bad = Self.entry("crash-200-1-11.txt", epoch: 200)
        let model = CrashLogsModel(
            directory: directory,
            loadEntries: { _ in [good, bad] },
            removeEntry: { url, _ in url == good.fileURL ? .deleted : .failed("nope") }
        )
        model.reload()

        await model.deleteAll(moveToTrash: false)

        #expect(model.entries.map(\.id) == ["crash-200-1-11.txt"])
        #expect(model.lastError == L10n.fmt("settings.crashLogs.deleteAllFailed.one", 1))
    }

    /// Several failures use the plural form.
    @Test
    func deleteAllReportsSeveralFailuresInThePlural() async {
        let directory = tempDirectory("delete-all-plural")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CrashLogsModel(
            directory: directory,
            loadEntries: { _ in
                [Self.entry("crash-100-1-11.txt"), Self.entry("crash-200-1-11.txt", epoch: 200)]
            },
            removeEntry: { _, _ in .failed("nope") }
        )
        model.reload()

        await model.deleteAll(moveToTrash: false)

        #expect(model.entries.count == 2)
        #expect(model.lastError == L10n.fmt("settings.crashLogs.deleteAllFailed.other", 2))
    }

    @Test
    func exportCopiesTheRecordFile() throws {
        let directory = tempDirectory("export")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("crash-100-1-11.txt")
        try "mackit-crash-log v1\ntime=100\n".write(to: source, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("exported.txt")
        let target = Self.entry("crash-100-1-11.txt", in: directory)
        let model = CrashLogsModel(
            directory: directory,
            loadEntries: { _ in [target] }
        )

        try model.export(target, to: destination)

        #expect(
            (try? String(contentsOf: destination, encoding: .utf8))?.contains("mackit-crash-log v1") == true
        )
    }

    /// The save panel asks about replacing; the copy therefore replaces
    /// rather than failing on an existing destination.
    @Test
    func exportReplacesAnExistingDestination() throws {
        let directory = tempDirectory("export-replace")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("crash-100-1-11.txt")
        try "new".write(to: source, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("exported.txt")
        try "old".write(to: destination, atomically: true, encoding: .utf8)
        let target = Self.entry("crash-100-1-11.txt", in: directory)
        let model = CrashLogsModel(directory: directory, loadEntries: { _ in [target] })

        try model.export(target, to: destination)

        #expect((try? String(contentsOf: destination, encoding: .utf8)) == "new")
    }

    /// A record whose file is already gone — pruned at launch, or removed
    /// from Finder — makes the copy throw. The view turns that into a toast,
    /// which is why the failure is thrown rather than stored.
    @Test
    func exportThrowsWhenTheRecordFileIsMissing() throws {
        let directory = tempDirectory("export-missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = Self.entry("crash-gone-1-11.txt")
        let model = CrashLogsModel(directory: directory, loadEntries: { _ in [target] })

        #expect(throws: (any Error).self) {
            try model.export(target, to: directory.appendingPathComponent("exported.txt"))
        }
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("exported.txt").path
            ) == false
        )
    }

    /// Symbolizing is a subprocess for an answer that cannot change, so the
    /// second tap on the same record must not pay for it again.
    @Test
    func symbolicationIsCachedPerRecord() async {
        let directory = tempDirectory("symbolicate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let count = SymbolicationCount()
        let target = Self.entry("crash-100-1-11.txt")
        let model = CrashLogsModel(
            directory: directory,
            loadEntries: { _ in [target] },
            symbolicateEntry: { entry in
                count.runs += 1
                return SymbolicationResult(
                    frames: entry.frames.map { SymbolizedFrame(address: $0, symbol: "main") },
                    unavailableReason: nil
                )
            }
        )

        await model.symbolicate(target)
        await model.symbolicate(target)

        #expect(count.runs == 1)
        #expect(model.symbolications["crash-100-1-11.txt"]?.frames.first?.symbol == "main")
    }

    @Test
    func revealGoesThroughTheInjectedClosure() {
        let directory = tempDirectory("reveal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let revealed = RevealedURLs()
        let target = Self.entry("crash-100-1-11.txt")
        let model = CrashLogsModel(
            directory: directory,
            loadEntries: { _ in [target] },
            revealEntry: { revealed.urls.append($0) }
        )

        model.revealInFinder(target)

        #expect(revealed.urls == [target.fileURL])
    }

    /// What the reveal seam was asked to show.
    private final class RevealedURLs: @unchecked Sendable {
        var urls: [URL] = []
    }
}
