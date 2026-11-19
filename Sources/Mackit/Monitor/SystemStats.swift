import Foundation
import Darwin

/// The three system load averages, as `getloadavg` reports them.
struct LoadAverage: Equatable, Sendable {
    var one: Double = 0
    var five: Double = 0
    var fifteen: Double = 0
    /// False when the kernel did not return all three values; the page then
    /// shows "—" instead of three fabricated zeros.
    var available: Bool = false
}

/// The memory split behind the memory page's composition bar.
struct MemoryComposition: Equatable, Sendable {
    /// App memory: anonymous pages minus the purgeable part.
    var app: Int64 = 0
    var wired: Int64 = 0
    var compressed: Int64 = 0
    /// File-backed cache: external pages plus purgeable and speculative.
    var cached: Int64 = 0
    var free: Int64 = 0

    /// The Activity Monitor "Memory Used" total: app memory + wired +
    /// compressed. `SystemStats.memoryUsed` reports this same figure.
    var used: Int64 { app + wired + compressed }
}

/// Swap usage as `vm.swapusage` reports it.
struct SwapUsage: Equatable, Sendable {
    var total: Int64 = 0
    var used: Int64 = 0
    var free: Int64 = 0

    /// Used share of the swap area, 0...1; 0 when no swap is configured.
    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(total)))
    }
}

/// One sample of system state: CPU usage, memory usage, and thermal state.
///
/// The monitoring section of the tray menu reads this data. All fields have
/// default values, so `SystemStats()` can be used directly as the initial value of the menu snapshot.
struct SystemStats: Equatable, Sendable {
    /// CPU usage, 0...1; nil means sampling failed or there is no comparable interval yet.
    var cpuUsage: Double? = nil
    /// Used memory: app memory + wired + compressed, matching the "Memory Used" figure in Activity Monitor.
    var memoryUsed: Int64 = 0
    /// Total physical memory.
    var memoryTotal: Int64 = 0
    /// Free memory. Speculative read-ahead pages are counted under cached
    /// files instead, so the composition's rows stay disjoint. The difference
    /// before and after a memory release is the amount actually released.
    var memoryFree: Int64 = 0
    /// System thermal state, `ProcessInfo.ThermalState.rawValue`.
    ///
    /// The only *public* temperature signal, and the fallback when no
    /// numeric reading is available. An Int is used rather than the enum
    /// itself so this struct fits a `Sendable` snapshot.
    var thermalState: Int = 0
    /// CPU temperature in °C, or nil when the SMC read answered with
    /// nothing usable. Read through the private SMC path (see
    /// `SMCTemperature`), which answers on this Apple Silicon machine —
    /// verified on a macOS 27 M2, whose sensor table answers with
    /// `flt `-typed values under load. Behavior on other OS versions and
    /// on Intel hardware is unverified; a machine where the path answers
    /// nothing falls back to the thermal state, never to a blank.
    var cpuTemperature: Double? = nil

    /// User-side share of CPU time, 0...1; nil on the baseline sample.
    var cpuUserFraction: Double? = nil
    /// System-side share of CPU time, 0...1; nil on the baseline sample.
    var cpuSystemFraction: Double? = nil
    /// Per-logical-core usage, 0...1, in host CPU order.
    ///
    /// Empty until two adjacent samples provide a comparable interval (and
    /// when `host_processor_info` fails): the UI renders no data rather than
    /// claiming every core is idle on the first frame.
    var cpuCores: [Double] = []
    /// Load averages from `getloadavg`.
    var loadAverage = LoadAverage()
    /// Memory split for the composition bar.
    var memoryComposition = MemoryComposition()
    /// Swap usage from `vm.swapusage`.
    var swap = SwapUsage()
    /// Page-in rate in bytes per second; nil on the baseline or after a gap
    /// longer than the sampling cadence.
    var pageInsPerSecond: Double? = nil
    /// Page-out rate in bytes per second; nil on the baseline or after a gap
    /// longer than the sampling cadence.
    var pageOutsPerSecond: Double? = nil
    /// Raw `kern.memorystatus_vm_pressure_level`; 0 when unavailable.
    var memoryPressureLevel: Int = 0
    /// System uptime in seconds.
    var uptime: TimeInterval = 0

    /// Used memory fraction, 0...1.
    var memoryUsedFraction: Double {
        guard memoryTotal > 0 else { return 0 }
        return min(1, max(0, Double(memoryUsed) / Double(memoryTotal)))
    }

    /// Whether the kernel reports the warning pressure level.
    ///
    /// The key is not documented in the SDK; the values the kernel publishes
    /// are 1 (normal), 2 (warning) and 4 (critical). An unknown or missing
    /// value is neither, which lets the UI fall back to used-fraction
    /// thresholds.
    var memoryPressureIsWarning: Bool { memoryPressureLevel == 2 }

    /// Whether the kernel reports the critical pressure level.
    var memoryPressureIsCritical: Bool { memoryPressureLevel >= 4 }

    /// The localization key for the thermal state, used wherever the
    /// temperature figure degrades to the thermal-state word (the menu bar
    /// item and the tray panel's pages).
    var thermalStateKey: String {
        switch ProcessInfo.ThermalState(rawValue: thermalState) {
        case .fair: return "menubar.thermal.fair"
        case .serious: return "menubar.thermal.serious"
        case .critical: return "menubar.thermal.critical"
        default: return "menubar.thermal.nominal"
        }
    }

    /// The temperature at or above which the display warns.
    ///
    /// Chosen against the parts this app runs on: an M2's sensor set
    /// averages about 82 °C under load and idles in the 60s, so a
    /// threshold down there would warn during ordinary use; the chip
    /// throttles near 100 °C. 95 sits between — it marks sustained
    /// heat, not a busy afternoon. Intel package sensors read far lower
    /// (proximity, not junction), so the warning is effectively an
    /// Apple-Silicon signal there.
    static let hotTemperature = 95.0

    /// The temperature value as the monitoring surfaces show it: whole
    /// degrees when the SMC answered, the thermal-state word when it did not.
    ///
    /// The fallback keeps the public signal rather than a placeholder: a
    /// machine whose sensor table answers nothing (or a future OS that
    /// closes the private path) still gets an honest temperature row — the
    /// thermal state, which is a real signal.
    var temperatureText: String {
        if let cpuTemperature { return Formatters.degrees(cpuTemperature) }
        return L10n.tr(thermalStateKey)
    }

    /// Whether the numeric reading sits at or above `hotTemperature`. False
    /// when there is no reading: a thermal state is not a temperature and
    /// must not be colored as one.
    var temperatureIsHot: Bool {
        guard let cpuTemperature else { return false }
        return cpuTemperature >= Self.hotTemperature
    }
}

/// A stateful sampler: CPU usage requires the tick difference between two
/// adjacent samples, so this is not a stateless function.
///
/// Sampling goes entirely through public interfaces (mach host info and
/// vm_statistics), with one exception: `SMCTemperature.readCPU()`, the
/// private SMC read behind the numeric temperature. It is additive — a
/// failure is a nil, and the monitoring section keeps showing the public
/// thermal state it always showed.
struct SystemStatsSampler: Sendable {
    /// Tick counters of the previous sample, one entry per logical core; the
    /// first sample has no comparable interval, so usage is nil.
    private var lastCPUTicks: [CoreCPUTicks]?
    /// The moment of the previous sample, for the page-rate interval.
    private var lastSampleTime: TimeInterval?
    /// Lifetime page counters of the previous sample.
    private var lastPageIns: UInt64?
    private var lastPageOuts: UInt64?

    /// Take one sample of system state.
    mutating func sample() -> SystemStats {
        let now = ProcessInfo.processInfo.systemUptime
        // A missing, zero or over-10-second interval would average over an
        // idle period (the panel was closed, the machine slept). Both the CPU
        // deltas and the page rates need a recent previous sample; this is a
        // new baseline.
        let elapsed: TimeInterval? = lastSampleTime.flatMap { previous in
            let interval = now - previous
            return interval > 0 && interval <= 10 ? interval : nil
        }

        var stats = SystemStats()

        let cores = Self.cpuTicks()
        // A long gap is a new baseline for CPU too: the view model treats a
        // fresh sample as current, so averaging over an idle period would
        // show a stale percentage as if it were happening now.
        Self.applyCPU(cores, previous: elapsed == nil ? nil : lastCPUTicks, to: &stats)
        lastCPUTicks = cores

        // When sampling fails, leave the whole memory block empty: the menu
        // shows "—" based on this, rather than presenting the failure as "0 bytes used".
        if let memory = Self.memorySnapshot() {
            stats.memoryUsed = memory.used
            stats.memoryTotal = memory.total
            stats.memoryFree = memory.free
            stats.memoryComposition = memory.composition
            if let elapsed, let lastIns = lastPageIns, let lastOuts = lastPageOuts {
                // The counters are page counts, so the delta becomes bytes
                // before it is divided by seconds. Wrapping subtraction
                // survives a counter reset; a huge result is still finite.
                stats.pageInsPerSecond =
                    Double(memory.pageIns &- lastIns) * Double(memory.pageSize) / elapsed
                stats.pageOutsPerSecond =
                    Double(memory.pageOuts &- lastOuts) * Double(memory.pageSize) / elapsed
            }
            lastPageIns = memory.pageIns
            lastPageOuts = memory.pageOuts
        } else {
            lastPageIns = nil
            lastPageOuts = nil
        }

        stats.swap = Self.swapUsage()
        stats.loadAverage = Self.loadAverage()
        stats.memoryPressureLevel = Self.memoryPressureLevel()
        stats.uptime = now
        stats.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        stats.cpuTemperature = SMCTemperature.readCPU()

        lastSampleTime = now
        return stats
    }

    /// Take a single memory breakdown.
    ///
    /// Memory sampling is independent of historical state, so the "released
    /// amount" of a memory release can take its baseline on the spot, without
    /// sharing state with the polling sampler. Returns nil on failure, letting
    /// the caller decide how to present it, rather than handing back data that
    /// looks normal but is actually all zeros.
    static func memoryUsage() -> (used: Int64, total: Int64, free: Int64)? {
        guard let memory = memorySnapshot() else { return nil }
        return (memory.used, memory.total, memory.free)
    }

    // MARK: - CPU

    /// Fills the CPU fields from the tick deltas of two adjacent samples.
    ///
    /// Every state is read as a 32-bit counter and subtracted with wrapping
    /// arithmetic: a Mac that has been up for weeks will see the kernel's
    /// `integer_t` counters wrap, and a signed subtraction across the wrap
    /// would turn the interval into a negative delta and poison the sample.
    private static func applyCPU(
        _ cores: [CoreCPUTicks]?,
        previous: [CoreCPUTicks]?,
        to stats: inout SystemStats
    ) {
        // A failed read, the first sample, or a changed core count has no
        // interval to compare; leaving cpuCores empty lets the page render
        // "no data" instead of drawing every core as idle.
        guard let cores, let previous, previous.count == cores.count else { return }
        var usages = [Double](repeating: 0, count: cores.count)

        var userTicks: UInt64 = 0
        var systemTicks: UInt64 = 0
        var totalTicks: UInt64 = 0
        for index in cores.indices {
            let user = UInt64(cores[index].user &- previous[index].user)
            let system = UInt64(cores[index].system &- previous[index].system)
            let nice = UInt64(cores[index].nice &- previous[index].nice)
            let idle = UInt64(cores[index].idle &- previous[index].idle)
            // nice is still CPU time spent on behalf of a user process;
            // folding it into user keeps the user/system split meaningful.
            let busy = user &+ nice &+ system
            let total = busy &+ idle
            userTicks &+= user &+ nice
            systemTicks &+= system
            totalTicks &+= total
            if total > 0 {
                usages[index] = min(1, Double(busy) / Double(total))
            }
        }

        // No ticks elapsed between the two reads: the fractions would be
        // meaningless, so the whole CPU block stays "no data".
        guard totalTicks > 0 else { return }
        stats.cpuCores = usages
        let user = Double(userTicks) / Double(totalTicks)
        let system = Double(systemTicks) / Double(totalTicks)
        stats.cpuUserFraction = min(1, user)
        stats.cpuSystemFraction = min(1, system)
        // Derive the total from the two parts so `user + system` equals
        // `cpuUsage` exactly; a third independent division would only agree
        // to within rounding.
        stats.cpuUsage = min(1, user + system)
    }

    /// Per-core tick counters from `host_processor_info`.
    ///
    /// The buffer returned by `host_processor_info` is owned by the caller and
    /// must be released with `vm_deallocate`, hence the defer.
    private static func cpuTicks() -> [CoreCPUTicks]? {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpuCount: natural_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count
        )
        // The release obligation holds from the moment the buffer is obtained:
        // any intermediate failure must still release it. Missing it once leaks
        // tens of KB, and this is a sample taken every two seconds.
        defer {
            if let info {
                vm_deallocate(
                    mach_task_self_, vm_address_t(bitPattern: info),
                    vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)
                )
            }
        }
        guard result == KERN_SUCCESS, let info, cpuCount > 0,
              Int(count) >= Int(cpuCount) * Int(CPU_STATE_MAX) else {
            return nil
        }

        let ticks = UnsafeBufferPointer(start: info, count: Int(count))
        var cores: [CoreCPUTicks] = []
        cores.reserveCapacity(Int(cpuCount))
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            cores.append(
                CoreCPUTicks(
                    user: UInt32(bitPattern: ticks[base + Int(CPU_STATE_USER)]),
                    system: UInt32(bitPattern: ticks[base + Int(CPU_STATE_SYSTEM)]),
                    nice: UInt32(bitPattern: ticks[base + Int(CPU_STATE_NICE)]),
                    idle: UInt32(bitPattern: ticks[base + Int(CPU_STATE_IDLE)])
                )
            )
        }
        return cores
    }

    // MARK: - Memory

    /// One `host_statistics64` read, shared by the full sample and the
    /// stateless `memoryUsage()`.
    private static func memorySnapshot() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.stride)

        // The buffer parameter type of host_statistics64 is integer_t;
        // vm_statistics64 must be rebound before it can be passed in.
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            MackitLog.system.error("memory sampling failed: host_statistics64 returned \(result)")
            return nil
        }

        // Page size goes through host_page_size rather than vm_kernel_page_size:
        // the latter is a global variable, not allowed to be read directly under strict concurrency.
        var pageSize = vm_size_t(0)
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            MackitLog.system.error("memory sampling failed: host_page_size invalid")
            return nil
        }
        let page = Int64(pageSize)
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        // `free_count` already includes speculative pages (per the SDK's
        // comment on vm_statistics64). They are shown under cached files
        // below, so they are subtracted here to keep every page in exactly
        // one legend row.
        let speculative = Int64(stats.speculative_count)
        let free = max(0, Int64(stats.free_count) - speculative) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        // App memory is anonymous memory minus the purgeable part the kernel
        // may reclaim at will; the clamp keeps a size the composition bar
        // prints from ever going negative.
        let app = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page
        let cached = (
            Int64(stats.external_page_count)
                + Int64(stats.purgeable_count)
                + speculative
        ) * page
        let composition = MemoryComposition(
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            free: free
        )
        // Used = app memory + wired + compressed: the same split the
        // composition bar shows, and the figure Activity Monitor's "Memory
        // Used" reports. Active pages include file-backed cache, which
        // Activity Monitor keeps separate, so `active_count` is not used.
        return MemorySnapshot(
            used: composition.used,
            total: total,
            free: free,
            composition: composition,
            pageIns: stats.pageins,
            pageOuts: stats.pageouts,
            pageSize: page
        )
    }

    /// Swap totals from `vm.swapusage`.
    ///
    /// A machine with swap disabled reports zeros; a missing key degrades the
    /// same way rather than failing the whole sample.
    private static func swapUsage() -> SwapUsage {
        // `xsw_usage` is imported from `sys/sysctl.h`; the kernel writes its
        // fields in the header's order, so no local copy of the layout is
        // needed.
        var info = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &info, &size, nil, 0) == 0 else {
            return SwapUsage()
        }
        return SwapUsage(
            total: Int64(info.xsu_total),
            used: Int64(info.xsu_used),
            free: Int64(info.xsu_avail)
        )
    }

    // MARK: - Load and pressure

    /// Load averages from `getloadavg`, which returns the number of values it
    /// filled; fewer than three means the reading is not usable.
    private static func loadAverage() -> LoadAverage {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return LoadAverage() }
        return LoadAverage(
            one: values[0],
            five: values[1],
            fifteen: values[2],
            available: true
        )
    }

    /// Raw memory pressure level.
    ///
    /// `kern.memorystatus_vm_pressure_level` is a sysctl key, not a private
    /// framework call, but the SDK does not document it; a missing key
    /// degrades to 0 and the UI falls back to used-fraction thresholds.
    private static func memoryPressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return 0
        }
        return Int(level)
    }
}

/// One core's CPU tick counters; subtracting two adjacent snapshots yields
/// the interval usage.
private struct CoreCPUTicks: Equatable, Sendable {
    let user: UInt32
    let system: UInt32
    let nice: UInt32
    let idle: UInt32
}

/// One `host_statistics64` read.
private struct MemorySnapshot {
    let used: Int64
    let total: Int64
    let free: Int64
    let composition: MemoryComposition
    let pageIns: UInt64
    let pageOuts: UInt64
    let pageSize: Int64
}
