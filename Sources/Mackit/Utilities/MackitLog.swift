import OSLog

/// Runtime diagnostic logging.
///
/// Everything goes through a unified `os.Logger` (subsystem = bundle ID); filter by
/// subsystem in the Console app to observe runtime behavior, or on the command line use:
///
/// ```
/// log stream --predicate 'subsystem == "cn.mingcui.mackit"' --level info
/// ```
///
/// Logging principles:
/// - Lifecycle events (scan / clean start, finish, cancel) and failures log at
///   `.info` / `.error`, kept in release builds too, so there is a record when problems
///   occur;
/// - Per-directory details (which paths were enumerated, which unreadable directories
///   were skipped) log at `.debug`, not persisted by default; add `--level debug` when
///   needed to see them;
/// - Only counts, sizes, durations, and rule ids are logged, never file contents; paths
///   appear only in error messages alongside the system error description (unavoidable)
///   and are not actively recorded anywhere else.
enum MackitLog {
    /// Unrelated to the App Group; takes the main bundle's id directly as the subsystem.
    static let subsystem = Bundle.main.bundleIdentifier ?? "cn.mingcui.mackit"

    /// Scan lifecycle.
    static let scan = Logger(subsystem: subsystem, category: "scan")
    /// Cleanup lifecycle and per-item results.
    static let clean = Logger(subsystem: subsystem, category: "clean")
    /// App discovery and residue probing.
    static let apps = Logger(subsystem: subsystem, category: "apps")
    /// System state sampling and memory release.
    static let system = Logger(subsystem: subsystem, category: "system")
    /// Window and app-form lifecycle.
    static let ui = Logger(subsystem: subsystem, category: "ui")
    /// Auto-update: updater launch, check intervals, and discovered versions.
    static let updates = Logger(subsystem: subsystem, category: "updates")
    /// Filesystem enumeration details.
    static let fs = Logger(subsystem: subsystem, category: "fs")

    /// Formats a duration into whole milliseconds, for interpolation in log messages.
    static func duration(_ interval: Duration) -> String {
        let components = interval.components
        let ms = Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1e15
        return String(format: "%.0fms", ms)
    }
}
