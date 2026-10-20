import Foundation

/// Shared settings storage for the two processes.
///
/// It originally used App Group
/// (`UserDefaults(suiteName: "group.cn.mingcui.mackit")`), but in practice
/// under ad-hoc signing the Group Container could not be resolved—after
/// cfpregs reported `Container: (null)` the entire preferences source was
/// detached, and the two processes each read and wrote their own
/// in-memory copy, with settings completely disconnected; it only
/// recovered after switching to a paid Developer ID signature.
/// Development iteration cannot be tied to a certificate, so shared files
/// were used instead: the two processes run under the same user, so the
/// same plist in Application Support is naturally shared, independent of
/// the signing method.
///
/// Writes are single-point: only the main program's settings page writes
/// (the tray panel is read-only), and it writes a temporary file first
/// then replaces atomically, so readers always see the complete previous
/// version, with no file lock needed.
@MainActor
enum SharedStore {
    /// Shared directory: ~/Library/Application Support/Mackit.
    static let directoryURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mackit", isDirectory: true)
    }()

    /// Shared settings file.
    static let settingsURL = directoryURL.appendingPathComponent("shared-settings.plist")

    /// Reads all settings. Returns an empty dictionary when the file does
    /// not exist or fails to read (each key falls back to its default).
    ///
    /// The file path is a parameter so tests can round-trip a settings file
    /// without touching the real one the two processes share.
    static func loadSettings(from url: URL = settingsURL) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    /// Writes all settings (atomic replacement). Only overwrites the keys
    /// passed in; keys not passed keep their original values—so adding
    /// other shared state to this file later will not wipe each other out.
    static func saveSettings(_ values: [String: Any], to url: URL = settingsURL) {
        var merged = loadSettings(from: url)
        merged.merge(values) { _, new in new }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: merged, format: .xml, options: 0
        ) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(UUID().uuidString).tmp")
        // A write failure only means the settings were not saved (the old
        // value is read next time, and each key falls back to its
        // default); it is not worth interrupting the caller over; the
        // temporary file is cleaned up by writeAtomically itself.
        try? writeAtomically(data, to: url, via: temporary)
    }

    /// Writes a temporary file first, then replaces the target: readers
    /// see either the old complete version or the new complete version,
    /// never a half-written plist.
    ///
    /// On failure of any step, clean up the temporary file before
    /// rethrowing. What must be cleaned up is the temporary file just
    /// written to disk: this once cleaned up "settingsURL/tmp"—a path
    /// hidden inside a file, which never exists, so every failed write
    /// leaked a temporary file in the shared directory.
    /// The path is injected via a parameter, making the failure path
    /// testable.
    static func writeAtomically(_ data: Data, to destination: URL, via temporary: URL) throws {
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// Pending commands for cold-start compensation.
///
/// When the agent wakes up the main program, the main program may not
/// have registered its notification observers yet, and a distributed
/// notification sent at that moment is lost. The command is first
/// written to disk and read when the main program launches. Stored in a
/// separate file from settings: settings writes are "read-modify-write";
/// if the two shared one file, a settings save could overwrite the
/// just-written pending command back to old content.
@MainActor
enum PendingCommandStore {
    static let fileURL = SharedStore.directoryURL.appendingPathComponent("pending-command.txt")

    /// The valid duration of a pending command.
    ///
    /// After the command is written to disk, if the main program does not
    /// come up for a long time (startup failure, killed on startup, or the
    /// user turning it off in login items), the command lies in the file
    /// until the user next opens the app on their own—at which point it
    /// should long since have stopped taking effect (the app
    /// inexplicably jumping to the hardware page, popping up the clean
    /// confirmation). Past this duration it is voided on the spot, and is
    /// never allowed to take effect across sessions.
    static let maxAge: TimeInterval = 120

    /// Records a command to be executed.
    static func write(_ command: AppCommand) {
        try? FileManager.default.createDirectory(
            at: SharedStore.directoryURL, withIntermediateDirectories: true
        )
        try? command.rawValue.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Reads and takes the pending command (read deletes). Returns nil
    /// when there is none, the content is unrecognized, or it has sat too
    /// long.
    ///
    /// Age is judged by the file's modification time rather than a
    /// timestamp written in the content: the file format stays "a single
    /// line of rawValue", so commands written by older versions are still
    /// recognized by newer ones.
    /// The module-internal visible fileURL parameter makes it easy for
    /// tests to inject a temporary path.
    static func take(fileURL: URL = PendingCommandStore.fileURL) -> AppCommand? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        guard let command = AppCommand(
            rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            // Unrecognized content is cleaned up as well: bad data should
            // not stay in the file and be parsed again on every startup
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        try? FileManager.default.removeItem(at: fileURL)

        // If the modification time cannot be obtained, treat it as new:
        // the cold-start main path matters more than the "just in case",
        // and the case where the content is readable but the attributes
        // are not almost never happens.
        if let modified, Date().timeIntervalSince(modified) > maxAge {
            MackitLog.ui.info("discarding stale pending command: \(command.rawValue, privacy: .public)")
            return nil
        }
        return command
    }
}
