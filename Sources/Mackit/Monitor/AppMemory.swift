import AppKit
import Darwin

/// A running app and its memory usage.
struct AppMemoryEntry: Equatable, Sendable, Identifiable {
    /// Process pid, the row identifier.
    let pid: Int
    let name: String
    /// The .app path; an empty string when unavailable, and the icon falls back to the generic app symbol.
    let path: String
    /// Physical memory usage. The phys_footprint from `proc_pid_rusage`,
    /// the same figure as the "Memory" column in Activity Monitor.
    let bytes: Int64

    var id: Int { pid }
}

/// Enumerate running apps by memory usage.
///
/// Two public interfaces: `NSWorkspace.runningApplications` for the app list,
/// `proc_pid_rusage` for each process's physical memory usage.
enum AppMemorySampler {
    /// How many apps to show by default. Any more and the panel would need to grow taller, but the tray panel should not scroll.
    static let defaultLimit = 6

    /// The top `limit` apps by memory usage.
    ///
    /// Only apps with the regular activation policy are counted — the ones the
    /// user can see in the Dock. Background daemons are not informative for
    /// "who is eating memory"; listing them would only push the real heavy
    /// users off the list.
    ///
    /// `NSWorkspace.runningApplications` requires the main thread, so the
    /// whole function is `@MainActor`; the caller (polling sampling) is
    /// already on the main thread.
    @MainActor
    static func topApps(limit: Int = defaultLimit) -> [AppMemoryEntry] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        var entries: [AppMemoryEntry] = []
        entries.reserveCapacity(apps.count)
        for app in apps {
            let pid = app.processIdentifier
            guard let bytes = footprint(pid: pid) else { continue }
            entries.append(
                AppMemoryEntry(
                    pid: Int(pid),
                    name: app.localizedName ?? "",
                    path: app.bundleURL?.path ?? "",
                    bytes: bytes
                )
            )
        }

        return entries
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { $0 }
    }

    /// The physical memory usage of a single process; returns nil when it cannot be read (process already exited, insufficient permission).
    static func footprint(pid: Int32) -> Int64? {
        // The buffer uses the largest version, v6: RUSAGE_INFO_CURRENT corresponds
        // to rusage_info_current. If it is too small, the kernel fills only the
        // front portion, and ri_phys_footprint may fall outside the buffer.
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard result == 0 else { return nil }
        return Int64(info.ri_phys_footprint)
    }
}
