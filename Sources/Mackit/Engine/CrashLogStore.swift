import Foundation

/// One collected crash record: the parsed form of a file `CrashCollector`
/// wrote.
///
/// A record is a summary, not a debugger session: what the process was
/// (version, build, system, role), what killed it (signal and fault
/// address, or the uncaught exception), and where (frame addresses). The
/// raw file stays the source of truth: the detail view renders these
/// parsed fields, and export hands the user that same file.
struct CrashLogEntry: Identifiable, Sendable, Hashable {
    /// File name. Stable across reloads, so it identifies the entry in the
    /// settings list and in the model's selection.
    let id: String
    let fileURL: URL
    let date: Date
    let pid: Int
    /// Whether the tray agent wrote it rather than the main app.
    let isAgent: Bool
    let appVersion: String
    let build: String
    let osVersion: String
    let executablePath: String
    /// 0 for an uncaught-exception record.
    let signal: Int32
    let signalName: String
    let faultAddress: UInt64?
    /// Return addresses, innermost first.
    let frames: [UInt64]
    /// The main executable's runtime image range, when the record carries
    /// it. `Symbolicator` needs both to decide which frames it can resolve.
    let imageHeader: UInt64?
    let imageEnd: UInt64?
    let exceptionName: String?
    let exceptionReason: String?

    /// Whether this record came from an uncaught Objective-C exception
    /// rather than a signal.
    var isException: Bool { exceptionName != nil }

    /// Which process wrote this record, as the settings row and the detail
    /// sheet name it. Two views show it, so the spelling lives with the
    /// record rather than in a ternary at each site.
    var processLabel: String {
        L10n.tr(isAgent ? "crashLogs.process.agent" : "crashLogs.process.app")
    }
}

/// Reading the collected crash logs: enumerate the records directory, parse
/// what is in it, keep it bounded.
///
/// Parsing is deliberately forgiving: a record is only ever written by a
/// process that is about to die, so a truncated file is the normal
/// corruption mode, not the exceptional one. A file that cannot be parsed
/// into a placed entry (no readable timestamp) is skipped and left on disk
/// rather than deleted — the user can still open it in a text editor.
enum CrashLogStore {
    /// How many records to keep. Crashes are rare and the files are a few
    /// hundred bytes, but "rare" is not "never": without a cap a machine
    /// that crashes on every launch would grow the directory forever, and
    /// the value has to be a number the settings list stays readable at.
    static let retentionLimit = 50

    /// The largest file that counts as a record. A real one is a header plus
    /// up to 64 frame lines — under 2 KB — so this bound is generous by two
    /// orders of magnitude and still stops a stray file from being read in
    /// full into memory.
    static let maxRecordBytes = 1_000_000

    /// Where the records live: the shared Application Support folder, beside
    /// the settings file. Both processes write here (see `CrashCollector`).
    static let directory = AppDirectories.crashLogs

    /// Every parseable record in `directory`, newest first.
    static func entries(in directory: URL = CrashLogStore.directory) -> [CrashLogEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { isRecordName($0.lastPathComponent) }
            .compactMap { entry(from: $0) }
            .sorted { lhs, rhs in
                lhs.date == rhs.date
                    ? lhs.id > rhs.id
                    : lhs.date > rhs.date
            }
    }

    /// Drops the oldest records beyond `limit` and reports how many went.
    ///
    /// Only ever removes files this enumeration itself produced from inside
    /// the records directory, with the collector's naming: the delete never
    /// acts on a path that came from anywhere else.
    @discardableResult
    static func prune(limit: Int = retentionLimit, in directory: URL = CrashLogStore.directory) -> Int {
        let entries = entries(in: directory)
        guard entries.count > limit else { return 0 }
        let doomed = entries.suffix(entries.count - limit)
        var removed = 0
        for entry in doomed {
            if (try? FileManager.default.removeItem(at: entry.fileURL)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            MackitLog.fs.info(
                "crash log prune: \(removed, privacy: .public) of \(entries.count, privacy: .public) records removed"
            )
        }
        return removed
    }

    /// Parses one record file, or nil when it is not one.
    ///
    /// The size guard is not tidiness: the records directory is user-writable,
    /// and anything that lands in it named `crash-*.txt` is read in full the
    /// moment the settings page opens. A record the collector writes is a few
    /// hundred bytes, so a file that claims to be one and is not is skipped
    /// rather than loaded.
    static func entry(from url: URL) -> CrashLogEntry? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maxRecordBytes else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, id: url.lastPathComponent, fileURL: url)
    }

    /// The file-name shape the collector writes: `crash-<epoch>-<pid>-<signal>.txt`.
    private static func isRecordName(_ name: String) -> Bool {
        name.hasPrefix("crash-") && name.hasSuffix(".txt")
    }

    /// Parses the record format. Unknown keys are ignored — a newer writer's
    /// fields must not make an older reader reject the record — and every
    /// value is optional: a record truncated mid-write keeps whatever landed
    /// before the process died.
    static func parse(_ text: String, id: String, fileURL: URL) -> CrashLogEntry? {
        var epoch: Int64?
        var pid = 0
        var isAgent = false
        var appVersion = ""
        var build = ""
        var osVersion = ""
        var executablePath = ""
        var signal: Int32 = 0
        var signalName = ""
        var faultAddress: UInt64?
        var frames: [UInt64] = []
        var imageHeader: UInt64?
        var imageEnd: UInt64?
        var exceptionName: String?
        var exceptionReason: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            switch key {
            case "time": epoch = Int64(value)
            case "pid": pid = Int(value) ?? 0
            case "role": isAgent = value == "agent"
            case "version": appVersion = value
            case "build": build = value
            case "os": osVersion = value
            case "executable": executablePath = value
            case "signal": signal = Int32(value) ?? 0
            case "signal-name": signalName = value
            case "fault-address": faultAddress = hex(value)
            case "image-header": imageHeader = hex(value)
            case "image-end": imageEnd = hex(value)
            case "exception": exceptionName = value
            case "exception-reason": exceptionReason = value
            case "frame":
                if let address = hex(value) { frames.append(address) }
            default: continue
            }
        }

        // Without a time the record cannot be placed in the list at all, so
        // it is not an entry. The file itself is left alone.
        guard let epoch else { return nil }
        return CrashLogEntry(
            id: id,
            fileURL: fileURL,
            date: Date(timeIntervalSince1970: Double(epoch)),
            pid: pid,
            isAgent: isAgent,
            appVersion: appVersion,
            build: build,
            osVersion: osVersion,
            executablePath: executablePath,
            signal: signal,
            signalName: signalName,
            faultAddress: faultAddress,
            frames: frames,
            imageHeader: imageHeader,
            imageEnd: imageEnd,
            exceptionName: exceptionName,
            exceptionReason: exceptionReason
        )
    }

    private static func hex(_ value: String) -> UInt64? {
        let digits = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        return UInt64(digits, radix: 16)
    }
}
