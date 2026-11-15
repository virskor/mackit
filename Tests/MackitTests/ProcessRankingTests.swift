import Darwin
import Testing

@testable import Mackit

/// Process grouping and ranking for the panel's "top consumers" lists.
///
/// The sampler's I/O is deliberately not exercised here: these tests feed
/// `ProcessSampler.rank` fixed `ProcessSampleEntry` readings, so grouping,
/// ordering and coverage are checked without depending on what happens to be
/// running (or readable) on the machine.
struct ProcessRankingTests {
    // MARK: Fixtures

    private func entry(
        pid: Int32,
        name: String,
        path: String?,
        memory: Int64,
        cpu: Double?
    ) -> ProcessSampleEntry {
        ProcessSampleEntry(
            pid: pid,
            name: name,
            path: path,
            memoryBytes: memory,
            cpuFraction: cpu
        )
    }

    // MARK: outerAppPath

    /// A helper's executable lives inside its own nested `.app`; the ranking
    /// must attribute it to the outermost bundle so it counts toward the app
    /// the user actually launched.
    @Test func outerAppPathFindsOutermostBundleForNestedHelpers() {
        #expect(
            ProcessSampler.outerAppPath(
                "/Applications/ZCode.app/Contents/Frameworks/ZCode Helper (Renderer).app/Contents/MacOS/ZCode Helper (Renderer)"
            ) == "/Applications/ZCode.app"
        )
        #expect(
            ProcessSampler.outerAppPath(
                "/Applications/Outer.app/Contents/PlugIns/Inner.app/Contents/XPCServices/Deep.app/Contents/MacOS/tool"
            ) == "/Applications/Outer.app"
        )
    }

    /// Daemons and frameworks are not apps. In particular, a `com.apple.*`
    /// component in a framework's XPC service path must not be mistaken for
    /// an application bundle.
    @Test func outerAppPathRejectsDaemonsAndFrameworkPaths() {
        #expect(ProcessSampler.outerAppPath("/usr/sbin/cupsd") == nil)
        #expect(
            ProcessSampler.outerAppPath(
                "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"
            ) == nil
        )
        #expect(
            ProcessSampler.outerAppPath(
                "/System/Library/Frameworks/Foundation.framework/Versions/C/XPCServices/com.apple.foundation.UserScriptService.xpc/Contents/MacOS/com.apple.foundation.UserScriptService"
            ) == nil
        )
        #expect(ProcessSampler.outerAppPath("/usr/libexec/com.apple.metadata.mds") == nil)
    }

    // MARK: Grouping

    /// The main executable and its helpers collapse into one row. Memory and
    /// CPU are sums, the process count is reported, and CPU is not clamped:
    /// a group using two cores must show 200%, not 100%.
    @Test func rankGroupsHelpersUnderTheirOuterApp() {
        let entries = [
            entry(
                pid: 10,
                name: "ZCode",
                path: "/Applications/ZCode.app/Contents/MacOS/ZCode",
                memory: 1_000,
                cpu: 0.5
            ),
            entry(
                pid: 11,
                name: "ZCode Helper (Renderer)",
                path: "/Applications/ZCode.app/Contents/Frameworks/ZCode Helper (Renderer).app/Contents/MacOS/ZCode Helper (Renderer)",
                memory: 500,
                cpu: 0.75
            ),
            entry(
                pid: 12,
                name: "Safari",
                path: "/Applications/Safari.app/Contents/MacOS/Safari",
                memory: 2_000,
                cpu: 0.1
            ),
        ]

        let ranking = ProcessSampler.rank(
            entries: entries,
            totalCount: 3,
            readableCount: 3,
            limit: 10
        )

        #expect(ranking.topCPU.map(\.name) == ["ZCode", "Safari"])
        let zcode = ranking.topCPU.first
        #expect(zcode?.path == "/Applications/ZCode.app")
        #expect(zcode?.memoryBytes == 1_500)
        #expect(zcode?.cpuFraction == 1.25)
        #expect(zcode?.processCount == 2)
        #expect(zcode?.isApp == true)

        #expect(ranking.topMemory.map(\.name) == ["Safari", "ZCode"])
        #expect(ranking.topMemory.first?.memoryBytes == 2_000)
    }

    /// The overview ranks apps from its own list, so every app group's total
    /// must survive even when `topMemory` is capped. Daemons have no bundle
    /// and stay out of the map.
    @Test func appFootprintsKeepEveryGroupUncapped() {
        let entries = [
            entry(
                pid: 30,
                name: "ZCode",
                path: "/Applications/ZCode.app/Contents/MacOS/ZCode",
                memory: 1_000,
                cpu: nil
            ),
            entry(
                pid: 31,
                name: "ZCode Helper",
                path: "/Applications/ZCode.app/Contents/Frameworks/ZCode Helper.app/Contents/MacOS/ZCode Helper",
                memory: 500,
                cpu: nil
            ),
            entry(
                pid: 32,
                name: "Safari",
                path: "/Applications/Safari.app/Contents/MacOS/Safari",
                memory: 2_000,
                cpu: nil
            ),
            entry(
                pid: 33,
                name: "mds",
                path: "/usr/libexec/mds",
                memory: 300,
                cpu: nil
            ),
        ]

        let ranking = ProcessSampler.rank(
            entries: entries,
            totalCount: 4,
            readableCount: 4,
            limit: 1
        )

        #expect(ranking.topMemory.count == 1)
        #expect(ranking.topMemory.first?.name == "Safari")
        #expect(ranking.appFootprints["/Applications/ZCode.app"] == 1_500)
        #expect(ranking.appFootprints["/Applications/Safari.app"] == 2_000)
        #expect(ranking.appFootprints["mds"] == nil)
        #expect(ranking.appFootprints.count == 2)
    }

    /// Daemons have no bundle, so they group by process name — including a
    /// daemon whose executable path exists but contains no `.app` component.
    /// Their rank path is empty and they are not apps.
    @Test func daemonsWithTheSameNameGroupTogether() {
        let entries = [
            entry(pid: 20, name: "mds", path: nil, memory: 100, cpu: 0.125),
            entry(pid: 21, name: "mds", path: nil, memory: 50, cpu: 0.25),
            entry(pid: 22, name: "mdworker", path: "/usr/libexec/mdworker", memory: 10, cpu: nil),
        ]

        let ranking = ProcessSampler.rank(
            entries: entries,
            totalCount: 3,
            readableCount: 3,
            limit: 10
        )

        #expect(ranking.topMemory.map(\.name) == ["mds", "mdworker"])
        let mds = ranking.topMemory.first
        #expect(mds?.path == "")
        #expect(mds?.isApp == false)
        #expect(mds?.memoryBytes == 150)
        #expect(mds?.cpuFraction == 0.375)
        #expect(mds?.processCount == 2)
    }

    /// A group whose processes all lack a CPU delta reports nil, never 0:
    /// zero would claim the process is idle when the truth is "not measured
    /// yet" (the first sample after start-up).
    @Test func groupWithoutAnyCPUDeltaStaysNil() throws {
        let entries = [
            entry(
                pid: 30,
                name: "Slack",
                path: "/Applications/Slack.app/Contents/MacOS/Slack",
                memory: 10,
                cpu: nil
            ),
            entry(
                pid: 31,
                name: "Slack Helper",
                path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper",
                memory: 20,
                cpu: nil
            ),
        ]

        let ranking = ProcessSampler.rank(
            entries: entries,
            totalCount: 2,
            readableCount: 2,
            limit: 10
        )
        let group = try #require(ranking.topCPU.first)

        #expect(group.cpuFraction == nil)
        #expect(group.memoryBytes == 30)
        #expect(group.processCount == 2)
    }

    // MARK: rusage units

    /// `rusage_info` CPU times are mach absolute-time ticks, not nanoseconds.
    /// The converted reading must agree with `getrusage`'s microseconds for
    /// the same process; dividing the raw ticks by 1e9 would be off by the
    /// machine's timebase (about 42x on Apple Silicon).
    @Test func rusageTimesConvertWithTheMachTimebase() throws {
        var work: UInt64 = 0
        for value in 0..<5_000_000 {
            work &+= UInt64(value)
        }
        #expect(work > 0)

        let usage = try #require(ProcessSampler.rusage(pid: getpid()))
        var resourceUsage = rusage()
        #expect(getrusage(RUSAGE_SELF, &resourceUsage) == 0)

        let getrusageSeconds = Double(resourceUsage.ru_utime.tv_sec)
            + Double(resourceUsage.ru_utime.tv_usec) / 1_000_000
        let converted = ProcessSampler.seconds(fromMachTicks: usage.userTime)

        #expect(converted > 0)
        #expect(abs(converted - getrusageSeconds) < 0.5)
    }

    // MARK: Sorting

    /// CPU order: descending, nil last, then memory descending, then name
    /// ascending. Each pair of adjacent rows below exercises one tie-break.
    @Test func cpuSortingOrdersByCPUThenMemoryThenNameWithNilLast() {
        let entries = [
            entry(pid: 40, name: "nil-cpu", path: nil, memory: 1_000, cpu: nil),
            entry(pid: 41, name: "beta", path: nil, memory: 5, cpu: 0.25),
            entry(pid: 42, name: "alpha", path: nil, memory: 5, cpu: 0.25),
            entry(pid: 43, name: "high", path: nil, memory: 0, cpu: 0.9),
            entry(pid: 44, name: "mid-mem-high", path: nil, memory: 900, cpu: 0.1),
            entry(pid: 45, name: "mid-mem-low", path: nil, memory: 100, cpu: 0.1),
        ]

        let ranking = ProcessSampler.rank(
            entries: entries,
            totalCount: 6,
            readableCount: 6,
            limit: 10
        )

        #expect(
            ranking.topCPU.map(\.name)
                == ["high", "alpha", "beta", "mid-mem-high", "mid-mem-low", "nil-cpu"]
        )
    }

    /// Memory order: descending memory, then CPU descending with nil last,
    /// then name ascending.
    @Test func memorySortingOrdersByMemoryThenCPUThenName() {
        let entries = [
            entry(pid: 50, name: "same-mem-nil-cpu", path: nil, memory: 1_000, cpu: nil),
            entry(pid: 51, name: "beta", path: nil, memory: 1_000, cpu: 0.5),
            entry(pid: 52, name: "alpha", path: nil, memory: 1_000, cpu: 0.5),
            entry(pid: 53, name: "largest", path: nil, memory: 2_000, cpu: nil),
        ]

        let ranking = ProcessSampler.rank(
            entries: entries,
            totalCount: 4,
            readableCount: 4,
            limit: 10
        )

        #expect(
            ranking.topMemory.map(\.name) == ["largest", "alpha", "beta", "same-mem-nil-cpu"]
        )
    }

    /// The limit caps each list independently; it never affects the process
    /// counts, which describe the whole sample.
    @Test func limitAppliesToBothRankings() {
        let entries = [
            entry(pid: 60, name: "a", path: nil, memory: 100, cpu: 0.5),
            entry(pid: 61, name: "b", path: nil, memory: 500, cpu: 0.4),
            entry(pid: 62, name: "c", path: nil, memory: 300, cpu: 0.3),
            entry(pid: 63, name: "d", path: nil, memory: 200, cpu: 0.2),
            entry(pid: 64, name: "e", path: nil, memory: 400, cpu: 0.1),
        ]

        let limited = ProcessSampler.rank(
            entries: entries,
            totalCount: 5,
            readableCount: 5,
            limit: 2
        )

        #expect(limited.topCPU.map(\.name) == ["a", "b"])
        #expect(limited.topMemory.map(\.name) == ["b", "e"])
        #expect(limited.totalCount == 5)
        #expect(limited.readableCount == 5)

        let unlimited = ProcessSampler.rank(
            entries: entries,
            totalCount: 5,
            readableCount: 5,
            limit: 99
        )
        #expect(unlimited.topCPU.count == 5)
        #expect(unlimited.topMemory.count == 5)
    }

    // MARK: Coverage

    /// Coverage is the share of listed processes the sampler could read; the
    /// UI shows a partial-data badge whenever it is below one.
    @Test func coverageIsReadableOverTotalAndDrivesIsPartial() {
        let entries = [
            entry(pid: 70, name: "alpha", path: nil, memory: 1, cpu: 0.1),
            entry(pid: 71, name: "beta", path: nil, memory: 2, cpu: 0.2),
        ]

        let partial = ProcessSampler.rank(
            entries: entries,
            totalCount: 10,
            readableCount: 5,
            limit: 10
        )

        #expect(abs(partial.coverage - 0.5) < 1e-12)
        #expect(partial.isPartial)
        #expect(partial.totalCount == 10)
        #expect(partial.readableCount == 5)

        let complete = ProcessSampler.rank(
            entries: entries,
            totalCount: 2,
            readableCount: 2,
            limit: 10
        )

        #expect(complete.coverage == 1)
        #expect(!complete.isPartial)
    }
}
