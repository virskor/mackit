import Foundation
import Testing

@testable import Mackit

/// The crash log store: parsing, ordering and retention.
///
/// Records are written by a process that is dying, so a truncated file is
/// the normal corruption mode — the fixtures here deliberately include
/// garbage and half-written records, and the contract is that they are
/// skipped rather than fatal. Everything runs in temporary directories.
struct CrashLogStoreTests {
    private func tempDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-store-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes one record file in the collector's format.
    private func writeRecord(
        _ name: String,
        in directory: URL,
        epoch: Int64,
        pid: Int = 100,
        signal: Int32 = 11,
        signalName: String = "SIGSEGV",
        frames: [UInt64] = [],
        version: String = "1.0.10",
        role: String = "app"
    ) throws {
        var text = """
        mackit-crash-log v1
        time=\(epoch)
        pid=\(pid)
        role=\(role)
        version=\(version)
        build=1
        os=Version 15.0.1 (Build 24A291)
        signal=\(signal)
        signal-name=\(signalName)

        """
        for frame in frames {
            text += "frame=0x\(String(frame, radix: 16))\n"
        }
        try text.write(
            to: directory.appendingPathComponent(name),
            atomically: true, encoding: .utf8
        )
    }

    @Test
    func entriesAreSortedNewestFirst() throws {
        let directory = tempDirectory("order")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRecord("crash-100-1-11.txt", in: directory, epoch: 100)
        try writeRecord("crash-300-1-11.txt", in: directory, epoch: 300)
        try writeRecord("crash-200-1-11.txt", in: directory, epoch: 200)

        let entries = CrashLogStore.entries(in: directory)

        #expect(entries.map(\.date.timeIntervalSince1970) == [300, 200, 100])
    }

    /// Two records from the same second — the same pid dying twice, or the
    /// app and the agent both going down — sort by file name so the order
    /// is deterministic. Row identity in the settings list depends on it.
    @Test
    func entriesWithTheSameEpochSortByIdDescending() throws {
        let directory = tempDirectory("tie")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRecord("crash-100-1-11.txt", in: directory, epoch: 100)
        try writeRecord("crash-100-2-11.txt", in: directory, epoch: 100)

        let entries = CrashLogStore.entries(in: directory)

        #expect(entries.map(\.id) == ["crash-100-2-11.txt", "crash-100-1-11.txt"])
    }

    /// A frame line that is not a number is skipped rather than fatal: the
    /// record is a dying process's last write, and a truncated line is the
    /// normal corruption mode.
    @Test
    func unparseableFrameLinesAreSkipped() throws {
        let directory = tempDirectory("bad-frame")
        defer { try? FileManager.default.removeItem(at: directory) }
        var text = """
        mackit-crash-log v1
        time=100
        pid=1
        role=app
        version=1.0.10
        signal=11
        signal-name=SIGSEGV
        frame=0x1000
        frame=not-a-number
        frame=0x2000

        """
        text += "\n"
        try text.write(
            to: directory.appendingPathComponent("crash-100-1-11.txt"),
            atomically: true, encoding: .utf8
        )

        let entry = try #require(CrashLogStore.entries(in: directory).first)

        #expect(entry.frames == [0x1000, 0x2000])
    }

    /// A zero-byte file is not an entry: the collector's `open` with
    /// O_TRUNC can leave one behind when the process dies between the two,
    /// and an empty file has nothing to list.
    @Test
    func emptyFilesAreSkipped() throws {
        let directory = tempDirectory("empty")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("crash-100-1-11.txt"))
        try writeRecord("crash-200-1-11.txt", in: directory, epoch: 200)

        #expect(CrashLogStore.entries(in: directory).map(\.id) == ["crash-200-1-11.txt"])
    }

    /// The whole point of the store's tolerance: a record the dying process
    /// never finished, a file that is not a record at all, and a valid one —
    /// only the valid one is listed, and none of them is deleted.
    @Test
    func damagedRecordsAreSkippedNotFatal() throws {
        let directory = tempDirectory("damaged")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRecord("crash-100-1-11.txt", in: directory, epoch: 100)
        // Truncated mid-write: the header landed, the frames did not.
        try "mackit-crash-log v1\ntime=200\npid=1\nrole=app\nvers".write(
            to: directory.appendingPathComponent("crash-200-1-11.txt"),
            atomically: true, encoding: .utf8
        )
        // No timestamp at all: not an entry, because it cannot be placed in
        // the list — but it stays on disk for a text editor.
        try "mackit-crash-log v1\npid=1\nsignal=11\n".write(
            to: directory.appendingPathComponent("crash-300-1-11.txt"),
            atomically: true, encoding: .utf8
        )
        try Data([0xff, 0xfe, 0x00, 0x01]).write(
            to: directory.appendingPathComponent("crash-400-1-11.txt")
        )

        let entries = CrashLogStore.entries(in: directory)

        #expect(entries.count == 2, "the valid record and the truncated one: \(entries.map(\.id))")
        #expect(entries.contains { $0.id == "crash-100-1-11.txt" })
        #expect(entries.contains { $0.id == "crash-200-1-11.txt" })
        // Nothing was cleaned up on the store's own initiative.
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(onDisk.count == 4)
    }

    @Test
    func nonRecordFilesAreIgnored() throws {
        let directory = tempDirectory("foreign")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRecord("crash-100-1-11.txt", in: directory, epoch: 100)
        try "notes".write(
            to: directory.appendingPathComponent("notes.txt"),
            atomically: true, encoding: .utf8
        )
        try "notes".write(
            to: directory.appendingPathComponent("crash-100-1-11.log"),
            atomically: true, encoding: .utf8
        )

        let entries = CrashLogStore.entries(in: directory)

        #expect(entries.map(\.id) == ["crash-100-1-11.txt"])
    }

    /// A file that claims to be a record but is far larger than any record
    /// the collector writes is skipped: the records directory is
    /// user-writable, and the settings page reads whatever lands in it. The
    /// padded file below is a valid record with a megabyte of junk appended.
    @Test
    func oversizedFilesAreSkipped() throws {
        let directory = tempDirectory("oversize")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRecord("crash-100-1-11.txt", in: directory, epoch: 100)
        var huge = try String(
            contentsOf: directory.appendingPathComponent("crash-100-1-11.txt"),
            encoding: .utf8
        )
        huge += String(repeating: "x", count: CrashLogStore.maxRecordBytes)
        try huge.write(
            to: directory.appendingPathComponent("crash-200-1-11.txt"),
            atomically: true, encoding: .utf8
        )

        let entries = CrashLogStore.entries(in: directory)

        #expect(entries.map(\.id) == ["crash-100-1-11.txt"])
    }

    /// The records live under the user's own Library, which the
    /// protected-path check deliberately leaves alone — and every delete
    /// goes through `CleanEngine.removeFromDisk`, whose check runs again at
    /// the mutation point. A future widening of the protected set to cover
    /// `~/Library/Application Support` would make every crash-log delete
    /// fail with "protected path", and only this test would say so.
    @Test
    func recordPathsAreNotProtected() {
        let record = CrashLogStore.directory.appendingPathComponent("crash-100-1-11.txt")

        #expect(!FileSystem.isProtected(record.path))
        #expect(!FileSystem.isProtected(CrashLogStore.directory.path))
    }

    @Test
    func pruneKeepsTheNewestRecordsAndRemovesTheRest() throws {
        let directory = tempDirectory("prune")
        defer { try? FileManager.default.removeItem(at: directory) }
        for epoch in 1...5 {
            try writeRecord("crash-\(epoch * 100)-1-11.txt", in: directory, epoch: Int64(epoch * 100))
        }

        let removed = CrashLogStore.prune(limit: 2, in: directory)
        let entries = CrashLogStore.entries(in: directory)

        #expect(removed == 3)
        #expect(entries.map(\.date.timeIntervalSince1970) == [500, 400])
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("crash-100-1-11.txt").path
            ) == false
        )
    }

    /// Under the limit, pruning does nothing — including not deleting.
    @Test
    func pruneBelowTheLimitIsANoOp() throws {
        let directory = tempDirectory("prune-noop")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRecord("crash-100-1-11.txt", in: directory, epoch: 100)

        #expect(CrashLogStore.prune(limit: 50, in: directory) == 0)
        #expect(CrashLogStore.entries(in: directory).count == 1)
    }

    /// A missing directory reads as empty rather than failing: the first
    /// launch, before anything has ever crashed, is the normal case.
    @Test
    func missingDirectoryReadsAsEmpty() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-store-missing-\(UUID().uuidString)", isDirectory: true)

        #expect(CrashLogStore.entries(in: directory).isEmpty)
    }

    /// Both views show the process name — the settings row's summary and the
    /// detail sheet's metadata — so the spelling lives on the entry itself.
    @Test
    func processLabelNamesTheRoleThatWroteTheRecord() throws {
        let directory = tempDirectory("role")
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRecord("crash-100-1-11.txt", in: directory, epoch: 100, role: "app")
        try writeRecord("crash-200-1-11.txt", in: directory, epoch: 200, role: "agent")

        let entries = CrashLogStore.entries(in: directory)
        let app = try #require(entries.first { !$0.isAgent })
        let agent = try #require(entries.first { $0.isAgent })

        #expect(app.processLabel == L10n.tr("crashLogs.process.app"))
        #expect(agent.processLabel == L10n.tr("crashLogs.process.agent"))
    }

    /// Every field the writer emits is one the reader recovers: the detail
    /// sheet shows all of them, and a field that parses to nothing shows as
    /// blank.
    @Test
    func everyFieldRoundTrips() throws {
        let directory = tempDirectory("fields")
        defer { try? FileManager.default.removeItem(at: directory) }
        var text = """
        mackit-crash-log v1
        time=1760000000
        pid=4242
        role=agent
        version=1.0.10
        build=42
        os=Version 15.0.1 (Build 24A291)
        executable=/Applications/Mackit.app/Contents/MacOS/Mackit
        image-header=0x100000000
        image-end=0x100010000
        signal=11
        signal-name=SIGSEGV
        fault-address=0x10
        frame=0x100001000
        frame=0x100002000
        unknown-future-field=ignored

        """
        text += "\n"
        try text.write(
            to: directory.appendingPathComponent("crash-1760000000-4242-11.txt"),
            atomically: true, encoding: .utf8
        )

        let entry = try #require(CrashLogStore.entries(in: directory).first)

        #expect(entry.date.timeIntervalSince1970 == 1760000000)
        #expect(entry.pid == 4242)
        #expect(entry.isAgent)
        #expect(entry.appVersion == "1.0.10")
        #expect(entry.build == "42")
        #expect(entry.osVersion == "Version 15.0.1 (Build 24A291)")
        #expect(entry.executablePath == "/Applications/Mackit.app/Contents/MacOS/Mackit")
        #expect(entry.imageHeader == 0x100000000)
        #expect(entry.imageEnd == 0x100010000)
        #expect(entry.faultAddress == 0x10)
        #expect(entry.frames == [0x100001000, 0x100002000])
    }
}
