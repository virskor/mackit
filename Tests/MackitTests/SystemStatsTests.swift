import AppKit
import Foundation
import Testing

@testable import Mackit

/// System monitoring sampling and memory-release mapping.
///
/// Specific values are deliberately not asserted here: CPU usage and memory
/// consumption depend on what the machine is running at the moment, so
/// asserting a fixed value would only yield a flaky test. What must be
/// guaranteed is the nature of the interface itself — sampling succeeds, the
/// breakdown is self-consistent, and failures map to results the user can
/// understand.
@MainActor
struct SystemStatsTests {
    // MARK: Sampling

    /// Sampling must produce a usable memory breakdown: the total equals the
    /// physical memory, and used + free does not exceed the total.
    @Test func sampleProducesConsistentMemoryBreakdown() {
        var sampler = SystemStatsSampler()
        let stats = sampler.sample()

        #expect(stats.memoryTotal > 0)
        #expect(stats.memoryUsed >= 0)
        #expect(stats.memoryFree >= 0)
        #expect(stats.memoryUsed + stats.memoryFree <= stats.memoryTotal)
        #expect(stats.memoryUsedFraction >= 0 && stats.memoryUsedFraction <= 1)
    }

    /// Memory sampling is independent of history: a fresh sample alone can
    /// serve as the baseline.
    @Test func memoryUsageIsStateless() {
        let first = SystemStatsSampler.memoryUsage()
        let second = SystemStatsSampler.memoryUsage()

        #expect(first?.total == second?.total)
        #expect(first?.total ?? 0 > 0)
    }

    /// CPU usage is the difference between two adjacent samples; only the
    /// second one yields an interval value.
    @Test func cpuUsageNeedsTwoSamples() async throws {
        var sampler = SystemStatsSampler()
        let first = sampler.sample()
        // With no comparable interval on the first sample it can only be nil;
        // it must not fabricate a 0.
        #expect(first.cpuUsage == nil)

        try await Task.sleep(for: .milliseconds(300))
        let second = sampler.sample()

        if let usage = second.cpuUsage {
            #expect(usage >= 0 && usage <= 1)
        }
    }

    /// CPU usage from consecutive samples must stay in 0...1: an accumulating
    /// overflow or division by zero will both show up here.
    @Test func cpuUsageStaysInRange() async throws {
        var sampler = SystemStatsSampler()
        for _ in 0..<5 {
            _ = sampler.sample()
            try await Task.sleep(for: .milliseconds(50))
        }
        let stats = sampler.sample()
        if let usage = stats.cpuUsage {
            #expect(usage >= 0 && usage <= 1)
        }
    }

    /// The default-constructed SystemStats must be directly usable as an
    /// initial value (the menu snapshot's default value is it).
    @Test func defaultStatsAreEmpty() {
        let stats = SystemStats()
        #expect(stats.cpuUsage == nil)
        #expect(stats.memoryTotal == 0)
        #expect(stats.memoryUsedFraction == 0)
    }
}

/// Memory release: command construction, orchestration, and result mapping.
///
/// `@MainActor` matches `MemoryReleaser.release`: the authorization dialog can
/// only run on the main thread, so the injected double also runs there.
@MainActor
struct MemoryReleaserTests {
    /// The script must be an elevated purge, and the command must use an
    /// absolute path: the shell after authorization does not guarantee that
    /// /usr/sbin is in PATH.
    @Test func scriptRequestsElevatedPurgeWithAbsolutePath() {
        let source = MemoryReleaser.script()

        #expect(source.contains("do shell script"))
        #expect(source.contains("with administrator privileges"))
        #expect(source.contains("/usr/sbin/purge"))
    }

    /// Freed amount = the difference in free memory before and after the run.
    @Test func releaseMeasuresFreedMemoryAcrossRun() async {
        // Baseline 1 GB, 1.5 GB after the run
        let values: [Int64?] = [1_000_000_000, 1_500_000_000]
        var index = 0

        let outcome = await MemoryReleaser.release(
            run: { _ in (nil, nil) },
            memoryFree: {
                defer { index += 1 }
                return values[min(index, values.count - 1)]
            }
        )

        #expect(outcome == .released(500_000_000))
    }

    /// When sampling fails the difference is untrustworthy; a freed amount
    /// must not be fabricated.
    @Test func releaseWithoutUsableSamplesReportsNoChange() async {
        let outcome = await MemoryReleaser.release(
            run: { _ in (nil, nil) },
            memoryFree: { nil }
        )
        #expect(outcome == .noChange)
    }

    /// A failed follow-up sample after a successful baseline must not report a
    /// freed amount either.
    @Test func releaseWithFailedFollowUpSampleReportsNoChange() async {
        var calls = 0
        let outcome = await MemoryReleaser.release(
            run: { _ in (nil, nil) },
            memoryFree: {
                calls += 1
                return calls == 1 ? 1_000 : nil
            }
        )
        #expect(outcome == .noChange)
    }

    /// What actually runs must be that elevated purge script.
    @Test func releaseRunsTheElevatedPurgeScript() async {
        var seen: String?

        _ = await MemoryReleaser.release(
            run: { source in
                seen = source
                return (nil, nil)
            },
            memoryFree: { 0 }
        )

        #expect(seen == MemoryReleaser.script())
    }

    /// No change in memory across the run must not be reported as 0 bytes —
    /// the user would think something ran but did nothing.
    @Test func releaseWithoutChangeIsItsOwnOutcome() async {
        let outcome = await MemoryReleaser.release(
            run: { _ in (nil, nil) },
            memoryFree: { 4_000_000 }
        )
        #expect(outcome == .noChange)
    }

    /// Cancellation in the authorization dialog must be reported separately;
    /// it cannot be called a failure.
    @Test func releaseReportsCancellation() async {
        let outcome = await MemoryReleaser.release(
            run: { _ in ("User cancelled", MemoryReleaser.cancelledErrorNumber) },
            memoryFree: { 0 }
        )
        #expect(outcome == .cancelled)
    }

    /// A failure must carry an explanation; the user needs to know why nothing
    /// was released.
    @Test func releaseCarriesFailureMessage() async {
        let outcome = await MemoryReleaser.release(
            run: { _ in ("Operation not permitted", 1) },
            memoryFree: { 0 }
        )
        #expect(outcome == .failed("Operation not permitted"))
    }

    /// Success with a freed amount → released, with the value carried back
    /// as-is.
    @Test func successWithFreedMemoryReportsAmount() {
        let outcome = MemoryReleaser.outcome(freed: 2_000_000_000, message: nil, number: nil)
        #expect(outcome == .released(2_000_000_000))
    }

    /// A negative difference (the system took up memory again during the
    /// sampling gap) also counts as no change.
    @Test func negativeDeltaIsTreatedAsNoChange() {
        let outcome = MemoryReleaser.outcome(freed: -1024, message: nil, number: nil)
        #expect(outcome == .noChange)
    }

    /// Without an error number it must not be mistaken for a cancellation.
    @Test func errorWithoutNumberIsAFailure() {
        let outcome = MemoryReleaser.outcome(freed: 0, message: "boom", number: nil)
        #expect(outcome == .failed("boom"))
    }
}

/// Sampling of the memory usage leaderboard.
@MainActor
struct AppMemoryTests {
    /// Sampling must produce an app list sorted in descending order, with no
    /// more entries than the limit.
    @Test func topAppsAreSortedAndLimited() {
        let apps = AppMemorySampler.topApps(limit: 3)

        #expect(apps.count <= 3)
        for pair in zip(apps, apps.dropFirst()) {
            #expect(pair.0.bytes >= pair.1.bytes, "排行榜必须降序")
        }
        for app in apps {
            #expect(app.bytes > 0, "列出来的应用都该有内存占用")
            #expect(!app.name.isEmpty, "名字不能为空")
            #expect(app.pid > 0, "pid 用作行标识，必须有效")
        }
    }

    /// Only regular apps are counted: background daemons would push the real
    /// heavy users off the list.
    @Test func topAppsExcludeBackgroundDaemons() {
        let apps = AppMemorySampler.topApps(limit: 50)
        let regular = Set<Int32>(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { $0.processIdentifier }
        )
        for app in apps {
            #expect(regular.contains(Int32(app.pid)), "\(app.name) 不是常规应用")
        }
    }

    /// When memory usage cannot be obtained it returns nil rather than 0 — 0
    /// would be taken to mean "this app uses no memory".
    @Test func footprintOfBogusProcessIsNil() {
        // Neither pid 0 nor an extreme pid should have a reading
        #expect(AppMemorySampler.footprint(pid: 0) == nil)
        #expect(AppMemorySampler.footprint(pid: Int32.max) == nil)
    }
}
