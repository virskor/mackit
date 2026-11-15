import Darwin
import Foundation

/// One process reading before app grouping; exposed for unit tests.
struct ProcessSampleEntry: Equatable, Sendable {
    let pid: Int32
    let name: String
    let path: String?
    let memoryBytes: Int64
    let cpuFraction: Double?
}

/// One grouped row in a "top consumers" list.
struct ProcessRank: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    /// Outer `.app` bundle path; empty for a daemon.
    let path: String
    let memoryBytes: Int64
    /// Fraction of one core; may exceed 1 for a multi-process group. nil when
    /// no CPU delta could be computed yet.
    let cpuFraction: Double?
    let processCount: Int
    let isApp: Bool
}

/// The two rankings and the coverage of the sample they came from.
struct ProcessRanking: Equatable, Sendable {
    var topCPU: [ProcessRank] = []
    var topMemory: [ProcessRank] = []
    var totalCount: Int = 0
    var readableCount: Int = 0
    /// Every app group's footprint, keyed by the outer `.app` path.
    ///
    /// `topMemory` is capped, but the overview ranks apps from its own list,
    /// so it needs the total of an app that may not be in the top rows. Only
    /// bundle-backed groups appear here: a daemon has no app path to key on.
    var appFootprints: [String: Int64] = [:]

    /// The share of listed processes whose data could be read and included.
    ///
    /// Some system processes are not readable by a user process; the pages
    /// say "partial data" instead of presenting the ranking as complete.
    /// With nothing listed there is nothing to be missing, so coverage is 0
    /// and the sample is not partial.
    var coverage: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, max(0, Double(readableCount) / Double(totalCount)))
    }

    var isPartial: Bool { totalCount > 0 && coverage < 1 }
}

/// Samples every process and groups the readable ones by app or name.
///
/// All interfaces are public libproc/mach calls that predate macOS 14.
/// `proc_pid_rusage` on a user process only succeeds for same-user processes;
/// that is expected, and an unreadable pid is reported through the coverage
/// figures rather than hidden.
struct ProcessSampler: Sendable {
    /// CPU counters from the previous sample, keyed by pid. The table is
    /// replaced wholesale each sample: a pid that exits and is reused must not
    /// inherit the old process's counters, or its first CPU reading would be
    /// nonsense.
    private var previousCounters: [Int32: ProcessCPUCounter] = [:]
    private var previousSampleTime: TimeInterval?

    init() {}

    /// Samples all readable processes and returns the top groups.
    mutating func sample(limit: Int = 8) -> ProcessRanking {
        let now = ProcessInfo.processInfo.systemUptime
        // A gap that is missing, zero or longer than 10 seconds means the
        // delta would average over an idle period (the panel was closed, the
        // machine slept). That is a new baseline, not a CPU percentage.
        let elapsed: TimeInterval? = previousSampleTime.flatMap { previous in
            let interval = now - previous
            return interval > 0 && interval <= 10 ? interval : nil
        }

        let pids = Self.allPids()
        var entries: [ProcessSampleEntry] = []
        entries.reserveCapacity(pids.count)
        var counters: [Int32: ProcessCPUCounter] = [:]
        counters.reserveCapacity(pids.count)
        var readableCount = 0

        for pid in pids {
            // An unreadable process still counts in totalCount; the ranking
            // simply cannot describe it.
            guard let usage = Self.rusage(pid: pid) else { continue }

            let counter = ProcessCPUCounter(user: usage.userTime, system: usage.systemTime)
            counters[pid] = counter

            var cpuFraction: Double?
            if let elapsed, let last = previousCounters[pid],
               counter.user >= last.user, counter.system >= last.system {
                // rusage times are mach absolute-time ticks, not nanoseconds:
                // on Apple Silicon one second is about 24 million ticks
                // (timebase 125/3), so dividing the raw delta by 1e9 would
                // underreport CPU by more than 40x. Counters going backwards
                // mean the pid was reused, so there is no interval to measure.
                let delta = (counter.user - last.user) &+ (counter.system - last.system)
                cpuFraction = Self.seconds(fromMachTicks: delta) / elapsed
            }

            let path = Self.executablePath(pid: pid)
            // A process whose name and executable path both fail to read has
            // no label to show; skip it rather than invent one, and let the
            // coverage figures report the missing data.
            guard let name = Self.processName(pid: pid, path: path) else { continue }
            readableCount += 1
            entries.append(
                ProcessSampleEntry(
                    pid: pid,
                    name: name,
                    path: path,
                    memoryBytes: usage.memoryBytes,
                    cpuFraction: cpuFraction
                )
            )
        }

        // Replace the table even when the listing failed: stale counters must
        // not be subtracted from a later sample.
        previousCounters = counters
        previousSampleTime = now

        return Self.rank(
            entries: entries,
            totalCount: pids.count,
            readableCount: readableCount,
            limit: limit
        )
    }

    /// Pure grouping/ranking, exposed for tests.
    static func rank(
        entries: [ProcessSampleEntry],
        totalCount: Int,
        readableCount: Int,
        limit: Int
    ) -> ProcessRanking {
        var groups: [String: RankGroup] = [:]
        groups.reserveCapacity(entries.count)

        for entry in entries {
            let outer = entry.path.flatMap(outerAppPath)
            let key: String
            let name: String
            let path: String
            let isApp: Bool
            if let outer {
                key = outer
                path = outer
                isApp = true
                name = appDisplayName(outer) ?? entry.name
            } else {
                // Daemons have no bundle; their process name is the only
                // stable grouping key, and it is what the user sees in
                // Activity Monitor.
                key = entry.name
                path = ""
                isApp = false
                name = entry.name
            }

            var group = groups[key] ?? RankGroup(
                id: key,
                name: name,
                path: path,
                isApp: isApp
            )
            group.memoryBytes += entry.memoryBytes
            group.processCount += 1
            // Members without a delta are skipped, not treated as zero: the
            // group's CPU is nil only when no member could be measured.
            if let cpu = entry.cpuFraction {
                group.cpuFraction = (group.cpuFraction ?? 0) + cpu
            }
            groups[key] = group
        }

        let ranks = groups.values.map { group in
            ProcessRank(
                id: group.id,
                name: group.name,
                path: group.path,
                memoryBytes: group.memoryBytes,
                cpuFraction: group.cpuFraction,
                processCount: group.processCount,
                isApp: group.isApp
            )
        }
        let capped = max(0, limit)
        var appFootprints: [String: Int64] = [:]
        appFootprints.reserveCapacity(groups.count)
        for group in groups.values where group.isApp {
            appFootprints[group.id] = group.memoryBytes
        }
        return ProcessRanking(
            topCPU: Array(ranks.sorted(by: cpuPrecedes).prefix(capped)),
            topMemory: Array(ranks.sorted(by: memoryPrecedes).prefix(capped)),
            totalCount: max(0, totalCount),
            readableCount: min(max(0, readableCount), max(0, totalCount)),
            appFootprints: appFootprints
        )
    }

    /// The outermost `.app` component of an executable path, e.g.
    /// "/Applications/ZCode.app" for a helper inside ZCode.app. nil for
    /// daemons.
    ///
    /// The first `.app` from the root is the bundle the user launched; nested
    /// helper bundles live under it and must not become their own rows. A
    /// `com.apple.*` path component is not an application just because it
    /// carries the reverse-DNS prefix; only the `.app` suffix counts.
    static func outerAppPath(_ path: String) -> String? {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            components.append(component)
            if component.hasSuffix(".app") {
                return "/" + components.joined(separator: "/")
            }
        }
        return nil
    }

    /// The app's display name: the outer bundle's file name without `.app`.
    private static func appDisplayName(_ outerPath: String) -> String? {
        guard let file = outerPath.split(separator: "/").last else { return nil }
        let name = file.hasSuffix(".app") ? file.dropLast(4) : file
        return name.isEmpty ? nil : String(name)
    }

    // MARK: - Sampling primitives

    /// One process's cumulative rusage: physical footprint and CPU times.
    ///
    /// Split out because `AppMemorySampler` reads the same footprint for the
    /// overview's app rows. Both views then agree on the figure, and the
    /// unsafe pointer rebound exists in one place instead of two.
    static func rusage(pid: Int32) -> (memoryBytes: Int64, userTime: UInt64, systemTime: UInt64)? {
        // `RUSAGE_INFO_CURRENT` is defined with `rusage_info_current`, which
        // is `rusage_info_v6` in this SDK. `proc_pid_rusage` takes no size
        // argument, so the buffer must be exactly that struct; a smaller
        // version would be overrun by the kernel instead of truncated.
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (
            memoryBytes: Int64(info.ri_phys_footprint),
            userTime: info.ri_user_time,
            systemTime: info.ri_system_time
        )
    }

    /// Mach absolute-time ticks → seconds.
    ///
    /// `rusage_info`'s CPU times are in mach absolute-time units, not
    /// nanoseconds; the timebase converts one to the other (125/3 on Apple
    /// Silicon, 1/1 on Intel). The timebase is fixed for the boot, so it is
    /// read once. Visible within the module for the regression test that
    /// compares a converted reading with `getrusage`.
    static func seconds(fromMachTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// The current pid list.
    ///
    /// `proc_listallpids` returns the number of pids written and takes the
    /// buffer size in bytes. A count equal to the capacity may be truncated,
    /// so the buffer doubles until the whole list fits.
    private static func allPids() -> [Int32] {
        var capacity = 1_024
        while capacity <= 1 << 20 {
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { raw in
                proc_listallpids(raw.baseAddress, Int32(raw.count))
            }
            guard count >= 0 else {
                MackitLog.system.debug("process list failed: proc_listallpids returned \(count)")
                return []
            }
            if Int(count) < capacity {
                return pids.prefix(Int(count)).filter { $0 > 0 }
            }
            capacity *= 2
        }
        return []
    }

    /// The executable path, which is what carries the enclosing `.app`.
    private static func executablePath(pid: Int32) -> String? {
        // proc_pidpath's buffer is PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN.
        // The macro is an expression the Clang importer does not import, so
        // the layout-sized constant is spelled out here.
        var buffer = [CChar](repeating: 0, count: 4 * 1_024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return decode(buffer, length: Int(length))
    }

    /// The process name, falling back to the executable's last path component.
    /// nil when both public reads answer nothing: a process with no readable
    /// label is skipped rather than given a fabricated, unlocalized one.
    private static func processName(pid: Int32, path: String?) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0 {
            let name = decode(buffer, length: Int(length))
            if !name.isEmpty { return name }
        }
        if let last = path?.split(separator: "/").last, !last.isEmpty {
            return String(last)
        }
        return nil
    }

    /// Decodes a NUL-terminated UTF-8 buffer, honoring the byte count the
    /// kernel returned.
    private static func decode(_ buffer: [CChar], length: Int) -> String {
        let bytes = buffer.prefix(length).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Ordering

    /// CPU descending, nil last, then memory descending, then name ascending.
    private static func cpuPrecedes(_ lhs: ProcessRank, _ rhs: ProcessRank) -> Bool {
        switch compareCPU(lhs.cpuFraction, rhs.cpuFraction) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame: break
        }
        if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
        return lhs.name < rhs.name
    }

    /// Memory descending, then CPU descending (nil last), then name ascending.
    private static func memoryPrecedes(_ lhs: ProcessRank, _ rhs: ProcessRank) -> Bool {
        if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
        switch compareCPU(lhs.cpuFraction, rhs.cpuFraction) {
        case .orderedDescending: return true
        case .orderedAscending: return false
        case .orderedSame: break
        }
        return lhs.name < rhs.name
    }

    /// Compares optional CPU fractions with "no reading" ordered last.
    private static func compareCPU(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
            return .orderedSame
        case (_?, nil):
            return .orderedDescending
        case (nil, _?):
            return .orderedAscending
        case (nil, nil):
            return .orderedSame
        }
    }
}

/// The previous sample's CPU counters for one pid.
private struct ProcessCPUCounter: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
}

/// Accumulates one output group while the entries are folded.
private struct RankGroup {
    let id: String
    let name: String
    let path: String
    let isApp: Bool
    var memoryBytes: Int64 = 0
    var cpuFraction: Double?
    var processCount: Int = 0
}
