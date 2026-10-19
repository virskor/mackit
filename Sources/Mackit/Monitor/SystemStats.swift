import Foundation
import Darwin

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
    /// Free memory. The difference before and after a memory release is the amount actually released.
    var memoryFree: Int64 = 0
    /// System thermal state, `ProcessInfo.ThermalState.rawValue`.
    ///
    /// macOS has no public API for numeric temperature values (the private
    /// path that reads the SMC is rejected by the kernel on macOS 27), so the
    /// thermal state is the only public system temperature signal. An Int is
    /// used rather than the enum itself so this struct fits a `Sendable` snapshot.
    var thermalState: Int = 0

    /// Used memory fraction, 0...1.
    var memoryUsedFraction: Double {
        guard memoryTotal > 0 else { return 0 }
        return min(1, max(0, Double(memoryUsed) / Double(memoryTotal)))
    }

    /// The localization key for the thermal state. Shared by the menu bar panel and the desktop floating window.
    var thermalStateKey: String {
        switch ProcessInfo.ThermalState(rawValue: thermalState) {
        case .fair: return "menubar.thermal.fair"
        case .serious: return "menubar.thermal.serious"
        case .critical: return "menubar.thermal.critical"
        default: return "menubar.thermal.nominal"
        }
    }
}

/// A stateful sampler: CPU usage requires the tick difference between two
/// adjacent samples, so this is not a stateless function.
///
/// Sampling goes entirely through public interfaces (mach host info and
/// vm_statistics). Tray monitoring is a resident feature; the cost of private
/// interfaces breaking with a system version is the whole monitoring section
/// disappearing, which is not worth gambling on.
struct SystemStatsSampler: Sendable {
    /// CPU ticks of the previous sample; the first sample has no comparable interval, so usage is nil.
    private var lastCPUTicks: CPUTicks?

    /// Take one sample of system state.
    mutating func sample() -> SystemStats {
        let ticks = Self.cpuTicks()
        var usage: Double? = nil
        if let ticks, let last = lastCPUTicks, ticks.total > last.total {
            usage = min(1, max(0, Double(ticks.used - last.used) / Double(ticks.total - last.total)))
        }
        lastCPUTicks = ticks

        // When sampling fails, leave the whole memory block empty: the menu
        // shows "—" based on this, rather than presenting the failure as "0 bytes used".
        let memory = Self.memoryUsage()
        return SystemStats(
            cpuUsage: usage,
            memoryUsed: memory?.used ?? 0,
            memoryTotal: memory?.total ?? 0,
            memoryFree: memory?.free ?? 0,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue
        )
    }

    /// Take a single memory breakdown.
    ///
    /// Memory sampling is independent of historical state, so the "released
    /// amount" of a memory release can take its baseline on the spot, without
    /// sharing state with the polling sampler. Returns nil on failure, letting
    /// the caller decide how to present it, rather than handing back data that
    /// looks normal but is actually all zeros.
    static func memoryUsage() -> (used: Int64, total: Int64, free: Int64)? {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
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
            MackitLog.system.error("内存采样失败：host_statistics64 返回 \(result)")
            return nil
        }

        // Page size goes through host_page_size rather than vm_kernel_page_size:
        // the latter is a global variable, not allowed to be read directly under strict concurrency.
        var pageSize = vm_size_t(0)
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            MackitLog.system.error("内存采样失败：host_page_size 无效")
            return nil
        }
        let page = Int64(pageSize)
        // Used = app memory + wired + compressed. Inactive pages can be reclaimed
        // by the kernel at any time; counting them in "used" would keep the number
        // pinned high and would not match Activity Monitor's figures either.
        let used = (Int64(stats.active_count) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        let free = Int64(stats.free_count) * page
        return (used, total, free)
    }

    /// Aggregate CPU ticks across all logical cores.
    ///
    /// The buffer returned by `host_processor_info` is owned by the caller and
    /// must be released with `vm_deallocate`, hence the defer.
    private static func cpuTicks() -> CPUTicks? {
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
        var used: Int64 = 0
        var total: Int64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = Int64(ticks[base + Int(CPU_STATE_USER)])
            let system = Int64(ticks[base + Int(CPU_STATE_SYSTEM)])
            let nice = Int64(ticks[base + Int(CPU_STATE_NICE)])
            let idle = Int64(ticks[base + Int(CPU_STATE_IDLE)])
            used += user + system + nice
            total += user + system + nice + idle
        }
        return CPUTicks(used: used, total: total)
    }
}

/// A CPU tick snapshot; subtracting two adjacent snapshots yields the interval usage.
private struct CPUTicks: Equatable {
    /// Busy ticks: user + system + nice.
    var used: Int64
    /// Total ticks: busy + idle.
    var total: Int64
}
