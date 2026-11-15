import Foundation
import Testing

@testable import Mackit

/// Detailed sampling: per-core CPU, memory composition, swap and load average.
///
/// Like `SystemStatsTests`, no fixed reading is asserted: load, swap and the
/// composition split depend on the machine and on what is running. What is
/// checked is the contract the panel renders — the CPU fields agree with each
/// other, composition fields are non-negative, swap accounting is
/// self-consistent, and the per-core array covers every logical CPU with
/// values in 0...1.
@MainActor
struct SystemStatsDetailTests {
    /// CPU fields need two adjacent samples; the first is only a baseline.
    /// An 80 ms gap keeps the test fast while still accumulating ticks on
    /// every core.
    private func samplePair() async throws -> (first: SystemStats, second: SystemStats) {
        var sampler = SystemStatsSampler()
        let first = sampler.sample()
        try await Task.sleep(for: .milliseconds(80))
        let second = sampler.sample()
        return (first, second)
    }

    // MARK: CPU

    /// The first sample has no previous tick counters to compare against, so
    /// every CPU fraction is nil. Fabricating 0 would draw an idle system
    /// while the first interval is simply unknown.
    @Test func firstSampleIsTheCPUBaseline() {
        var sampler = SystemStatsSampler()
        let stats = sampler.sample()

        #expect(stats.cpuUsage == nil)
        #expect(stats.cpuUserFraction == nil)
        #expect(stats.cpuSystemFraction == nil)
    }

    @Test func secondSampleCPUFieldsStayInRange() async throws {
        let (_, stats) = try await samplePair()

        if let usage = stats.cpuUsage {
            #expect(usage >= 0 && usage <= 1)
        }
        if let user = stats.cpuUserFraction {
            #expect(user >= 0 && user <= 1)
        }
        if let system = stats.cpuSystemFraction {
            #expect(system >= 0 && system <= 1)
        }
    }

    /// The three CPU fields are derived from the same tick deltas. When a
    /// sample provides all of them, the parts must add up to the whole, or
    /// the ring and the chart legend disagree by more than rounding.
    @Test func userAndSystemAddUpToUsage() async throws {
        let (_, stats) = try await samplePair()

        guard let usage = stats.cpuUsage,
              let user = stats.cpuUserFraction,
              let system = stats.cpuSystemFraction else {
            // A baseline or a failed read may omit the fields; the identity
            // is asserted only when the sample provides all three.
            return
        }

        #expect(abs(user + system - usage) < 1e-9)
    }

    /// `cpuCores` must describe every logical CPU, in host order, with each
    /// value a fraction of one core. A missing or extra entry would shift
    /// the core labels in the grid.
    @Test func perCoreUsageCoversEveryLogicalCoreInRange() async throws {
        let (_, stats) = try await samplePair()

        #expect(!stats.cpuCores.isEmpty)
        #expect(stats.cpuCores.count == SystemInfo.logicalCoreCount)
        for usage in stats.cpuCores {
            #expect(usage.isFinite)
            #expect(usage >= 0 && usage <= 1)
        }
    }

    // MARK: Memory, swap, load, uptime

    /// Page counts and byte conversions can go negative when a subtraction
    /// underflows or the page-size read fails; every composition field is a
    /// size the UI prints, so each must stay non-negative.
    @Test func memoryCompositionIsNonNegative() {
        var sampler = SystemStatsSampler()
        let stats = sampler.sample()
        let composition = stats.memoryComposition

        #expect(stats.memoryTotal > 0)
        #expect(composition.app >= 0)
        #expect(composition.wired >= 0)
        #expect(composition.compressed >= 0)
        #expect(composition.cached >= 0)
        #expect(composition.free >= 0)
        #expect(composition.used >= 0)
        // The dashboard "used" figure is the composition's own total, so the
        // memory page's header cannot disagree with its composition bar.
        #expect(stats.memoryUsed == composition.used)
    }

    @Test func swapUsageIsSelfConsistent() {
        var sampler = SystemStatsSampler()
        let swap = sampler.sample().swap

        #expect(swap.total >= 0)
        #expect(swap.used >= 0)
        #expect(swap.free >= 0)
        // A machine with swap disabled reports zeros; the relationship must
        // still hold rather than showing negative free space.
        #expect(swap.total >= swap.used)
        if swap.total > 0 {
            #expect(swap.usedFraction >= 0 && swap.usedFraction <= 1)
        }
    }

    @Test func loadAverageIsAvailableWithNonNegativeValues() {
        var sampler = SystemStatsSampler()
        let load = sampler.sample().loadAverage

        #expect(load.available, "getloadavg returns three values on macOS")
        #expect(load.one.isFinite && load.one >= 0)
        #expect(load.five.isFinite && load.five >= 0)
        #expect(load.fifteen.isFinite && load.fifteen >= 0)
    }

    @Test func uptimeIsPositive() {
        var sampler = SystemStatsSampler()
        #expect(sampler.sample().uptime > 0)
    }

    /// The stateless memory snapshot is shared with `MemoryReleaser`; it must
    /// keep returning a usable total and a used/free split that fits inside
    /// it.
    @Test func memoryUsageSnapshotStaysConsistent() throws {
        let memory = try #require(SystemStatsSampler.memoryUsage())

        #expect(memory.total > 0)
        #expect(memory.used >= 0)
        #expect(memory.free >= 0)
        #expect(memory.used + memory.free <= memory.total)
    }

    // MARK: Process ranking

    /// A real sample must stay bounded and self-consistent whatever the
    /// machine is running. Coverage is deliberately not pinned: some system
    /// processes are unreadable, and how many varies between machines.
    @Test func processSamplerReturnsBoundedConsistentRanks() {
        var sampler = ProcessSampler()
        let ranking = sampler.sample(limit: 3)

        #expect(ranking.topCPU.count <= 3)
        #expect(ranking.topMemory.count <= 3)
        #expect(ranking.totalCount >= 1, "the sampler must at least list its own process")
        #expect(ranking.readableCount >= 0)
        #expect(ranking.readableCount <= ranking.totalCount)
        #expect(ranking.coverage >= 0 && ranking.coverage <= 1)

        for rank in ranking.topCPU + ranking.topMemory {
            #expect(!rank.name.isEmpty)
            #expect(rank.memoryBytes >= 0)
            #expect(rank.processCount >= 1)
            // The path is the outer bundle for an app and empty for a daemon.
            if rank.isApp {
                #expect(!rank.path.isEmpty)
            } else {
                #expect(rank.path.isEmpty)
            }
            if let cpu = rank.cpuFraction {
                #expect(cpu.isFinite && cpu >= 0)
            }
        }
    }
}
