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
}
