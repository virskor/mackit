import AppKit

/// A running app and its memory usage.
struct AppMemoryEntry: Equatable, Sendable, Identifiable {
    /// Process pid, the row identifier.
    let pid: Int
    let name: String
    /// The .app path; an empty string when unavailable, and the icon falls back to the generic app symbol.
    let path: String
    /// Physical memory usage. It is the whole app group's total — the main
    /// process plus every helper — whenever the process ranking has a reading
    /// for the bundle, which is the same figure the memory page lists. Falls
    /// back to the main process's `phys_footprint` from `proc_pid_rusage`
    /// when the ranking has no matching group.
    let bytes: Int64

    var id: Int { pid }
}

/// Enumerate running apps by memory usage.
///
/// The app list comes from `NSWorkspace.runningApplications`; each figure
/// comes from the process ranking's grouped totals, or from
/// `ProcessSampler.rusage` when the ranking has no entry yet.
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
    /// Each app's figure is its whole process group — helpers included — when
    /// `groupedMemory` has a total for the bundle, so the overview and the
    /// memory page report the same number. A missing entry (the ranking has
    /// not sampled yet, or the bundle path matches no process path) falls
    /// back to the main process's own footprint rather than dropping the app.
    ///
    /// `NSWorkspace.runningApplications` requires the main thread, so the
    /// whole function is `@MainActor`; the caller (polling sampling) is
    /// already on the main thread.
    @MainActor
    static func topApps(
        groupedMemory: [String: Int64],
        limit: Int = defaultLimit
    ) -> [AppMemoryEntry] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }

        var entries: [AppMemoryEntry] = []
        entries.reserveCapacity(apps.count)
        for app in apps {
            let pid = app.processIdentifier
            let bundlePath = app.bundleURL?.path ?? ""
            let grouped = groupedBytes(bundlePath: bundlePath, groupedMemory: groupedMemory)
            guard let bytes = grouped ?? footprint(pid: pid) else { continue }
            entries.append(
                AppMemoryEntry(
                    pid: Int(pid),
                    name: app.localizedName ?? "",
                    path: bundlePath,
                    bytes: bytes
                )
            )
        }

        return entries
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { $0 }
    }

    /// The process ranking's total for an app bundle, if it has one.
    ///
    /// The ranking keys its groups by `ProcessSampler.outerAppPath`, so the
    /// same normalization runs here. Split out so tests can feed a map
    /// without depending on what is running.
    static func groupedBytes(bundlePath: String, groupedMemory: [String: Int64]) -> Int64? {
        guard let outer = ProcessSampler.outerAppPath(bundlePath) else { return nil }
        return groupedMemory[outer]
    }

    /// The physical memory usage of a single process; returns nil when it cannot be read (process already exited, insufficient permission).
    static func footprint(pid: Int32) -> Int64? {
        ProcessSampler.rusage(pid: pid)?.memoryBytes
    }
}
