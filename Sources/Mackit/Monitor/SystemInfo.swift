import Foundation

/// Static facts about this Mac that the tray panel and the hardware page share.
///
/// These values stop changing once the machine boots, so they are read once
/// and cached instead of being sampled per frame. A read that answers nothing
/// degrades to an empty string or zero, never to a crash — a missing sysctl
/// only means the row shows "—".
enum SystemInfo {
    /// Marketing processor name, e.g. "Apple M2"; empty when the sysctl
    /// answers nothing.
    static let cpuName = Sysctl.string("machdep.cpu.brand_string") ?? ""

    /// Logical CPUs, matching `host_processor_info`'s per-core array.
    ///
    /// `hw.logicalcpu` counts SMT threads on Intel, which is exactly the
    /// entries the per-core sampler reports; `hw.ncpu` is the fallback for
    /// kernels that lack the logical count.
    static let logicalCoreCount = Sysctl.int("hw.logicalcpu") ?? Sysctl.int("hw.ncpu") ?? 0

    /// Physical cores, used by the core summary.
    ///
    /// The fallback is `hw.ncpu`, matching the core-description logic this
    /// replaced; a failed `hw.physicalcpu` read must still leave a usable
    /// total rather than zero.
    static let physicalCoreCount = Sysctl.int("hw.physicalcpu") ?? Sysctl.int("hw.ncpu") ?? 0

    /// Performance-cluster core count, when the standard two-cluster layout
    /// is readable.
    static let performanceCores: Int? = levelCores(0, name: "Performance")
    /// Efficiency-cluster core count, when the standard two-cluster layout
    /// is readable.
    static let efficiencyCores: Int? = levelCores(1, name: "Efficiency")

    /// Core description, e.g. "8 (4 performance + 4 efficiency)" or
    /// "8 cores"; empty when the total is unknown.
    ///
    /// Apple Silicon splits into performance / efficiency clusters; writing
    /// them separately is what makes it informative. Intel and cases where
    /// cluster info is unavailable report only the total core count. The
    /// hardware page keeps the empty spelling for an unknown total.
    static var coreDescription: String {
        let total = physicalCoreCount
        guard total > 0 else { return "" }

        // Only Apple Silicon has perflevel nodes; two clusters
        // (performance + efficiency) are its standard form; when the count
        // does not match (three-cluster new chips) report only the total,
        // without forcing the format.
        if let performance = performanceCores,
           let efficiency = efficiencyCores,
           performance + efficiency == total {
            return L10n.fmt("hw.cpu.coresSplit", total, performance, efficiency)
        }
        return L10n.fmt("hw.cpu.cores", total)
    }

    /// Core summary for the tray panel: `coreDescription`, or "—" when the
    /// total is unknown.
    ///
    /// The processor page's ring grid has one ring per logical CPU, so an
    /// Intel machine with hyper-threading reports both counts; a grid that
    /// says "6 cores" over twelve rings would be wrong. The hardware page
    /// keeps the physical-core description.
    static var coreSummary: String {
        coreSummaryText(
            physical: physicalCoreCount,
            logical: logicalCoreCount,
            description: coreDescription
        )
    }

    /// The pure form of `coreSummary`, so the Intel hyper-threading case is
    /// testable without depending on the running machine.
    static func coreSummaryText(physical: Int, logical: Int, description: String) -> String {
        guard physical > 0 else { return "—" }
        if logical > physical {
            return L10n.fmt("hw.cpu.coresThreads", physical, logical)
        }
        return description.isEmpty ? "—" : description
    }

    /// The core count of one perflevel node, when the machine reports the
    /// standard two-cluster layout under that cluster's name.
    private static func levelCores(_ index: Int, name: String) -> Int? {
        guard Sysctl.int("hw.nperflevels") == 2,
              Sysctl.string("hw.perflevel\(index).name") == name,
              let cores = Sysctl.int("hw.perflevel\(index).physicalcpu"),
              cores > 0 else { return nil }
        return cores
    }
}
