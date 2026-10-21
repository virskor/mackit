import Foundation
import Testing

@testable import Mackit

/// Boundary behavior of display formatting.
struct FormattersTests {
    /// Disk capacity escalates to TB at 1000 GB: a 4 TB drive shown as "4000 GB" is unreadable.
    @Test func capacityEscalatesToTerabytes() {
        #expect(Formatters.capacity(494_000_000_000).contains("494"))
        #expect(!Formatters.capacity(494_000_000_000).contains("TB"))
        #expect(Formatters.capacity(4_000_000_000_000).contains("4"))
        #expect(Formatters.capacity(4_000_000_000_000).contains("TB"))
        // Below 1 GB, fall back to the regular format instead of showing "0 GB"
        #expect(!Formatters.capacity(512).contains("GB"))
    }

    /// NaN must be displayed as 0%, not 100%: Swift's min/max returns the
    /// non-NaN side when it encounters NaN, so applying clamp directly would
    /// show a failed sample as maxed out.
    @Test func percentMapsNaNToZero() {
        #expect(Formatters.percent(.nan) == "0%")
        #expect(Formatters.percent(0) == "0%")
        #expect(Formatters.percent(1) == "100%")
        #expect(Formatters.percent(0.5) == "50%")
        // Out-of-range values are likewise clamped
        #expect(Formatters.percent(-1) == "0%")
        #expect(Formatters.percent(2) == "100%")
    }

    /// Memory uses base-1024 with GB units, consistent with the system's "About This Mac".
    @Test func memoryUsesBinaryGigabytes() {
        #expect(Formatters.memory(16 * 1024 * 1024 * 1024).contains("16"))
        #expect(Formatters.memory(16 * 1024 * 1024 * 1024).contains("GB"))
    }

    /// The treemap tiles need the mockup's tighter format: no space between
    /// number and unit, and two decimals even for round values, so tiles next
    /// to each other don't read as inconsistent.
    @Test func compactBytesDropsTheSpaceAndKeepsDecimals() {
        #expect(Formatters.compactBytes(206_530_000_000) == "206.53GB")
        #expect(Formatters.compactBytes(5_000_000_000) == "5.00GB")
        #expect(Formatters.compactBytes(740_350_000) == "740.35MB")
        // Escalates to TB at 1000 GB
        #expect(Formatters.compactBytes(4_000_000_000_000) == "4.00TB")
        // Below 1 MB falls back to KB / B, never "0 MB"
        #expect(Formatters.compactBytes(512) == "512B")
        #expect(!Formatters.compactBytes(512).contains("MB"))
        #expect(Formatters.compactBytes(1536) == "1.5KB")
        #expect(Formatters.compactBytes(0) == "0B")
    }

    /// Elapsed and remaining time read as a clock: m:ss, rolling over to
    /// h:mm:ss past an hour. Seconds are zero-padded so the width doesn't
    /// jitter as the readout ticks, and a negative duration (a clock read
    /// across a sleep boundary) clamps to zero rather than rendering "-1:-5".
    @Test func clockPadsSecondsAndRollsOverToHours() {
        #expect(Formatters.clock(.zero) == "0:00")
        #expect(Formatters.clock(.seconds(9)) == "0:09")
        #expect(Formatters.clock(.seconds(65)) == "1:05")
        #expect(Formatters.clock(.seconds(599)) == "9:59")
        #expect(Formatters.clock(.seconds(600)) == "10:00")
        #expect(Formatters.clock(.seconds(3_600)) == "1:00:00")
        #expect(Formatters.clock(.seconds(3_725)) == "1:02:05")
        #expect(Formatters.clock(.seconds(-5)) == "0:00")
        // Sub-second parts are truncated, not rounded up: 1.9 s must not read
        // as 0:02 while the next second has not fully elapsed.
        #expect(Formatters.clock(.milliseconds(1_900)) == "0:01")
    }
}
