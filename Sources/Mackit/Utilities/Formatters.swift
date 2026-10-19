import Foundation

/// Formatting utilities.
///
/// Design constraints:
/// - `bytes` / `percent` are pure functions, safe to use on any thread;
/// - `relative` depends on `RelativeDateTimeFormatter`, which is not `Sendable`, so the
///   cached instance is confined to the main thread, and all callers are view layer.
enum Formatters {
    /// Size formatting, e.g. "1.2 GB".
    ///
    /// Uses `ByteCountFormatStyle` rather than a shared `ByteCountFormatter` instance:
    /// the former is a pure Swift implementation and `Sendable`, whereas the latter, as
    /// an `NSFormatter` subclass, is not thread-safe, and a shared instance would
    /// constitute a data race when accessed concurrently by the scan and the UI.
    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    /// Memory capacity, e.g. "16 GB".
    ///
    /// Counts in binary multiples but writes the unit as GB—consistent with the system's
    /// "About This Mac": a 16 GiB machine shows 16 GB there. The hardware page's memory
    /// row follows suit, otherwise it would display as 17 GB.
    static func memory(_ value: Int64) -> String {
        let gib = Double(value) / Double(1 << 30)
        if gib >= 1 { return L10n.fmt("format.gigabytes", Int(gib.rounded())) }
        return bytes(value)
    }

    /// Disk capacity rounded to whole GB, e.g. "494 GB"; rolls over to TB at 1000 GB.
    ///
    /// `bytes` keeps two decimal places, as the list and sidebar need precision down to
    /// the hundredth; the hardware page's capacity row only needs one order of magnitude,
    /// where 494 GB reads better than 494.38 GB. Below 1 GB, falls back to the regular
    /// format.
    static func capacity(_ value: Int64) -> String {
        let gb = Double(value) / 1_000_000_000
        if gb >= 1000 { return L10n.fmt("format.terabytes", Int((gb / 1000).rounded())) }
        if gb >= 1 { return L10n.fmt("format.gigabytes", Int(gb.rounded())) }
        return bytes(value)
    }

    /// Relative time, e.g. "3 hours ago".
    @MainActor
    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    @MainActor
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func percent(_ fraction: Double) -> String {
        // NaN must be filtered out first: Swift's min/max return the non-NaN side when
        // encountering NaN, so applying it directly would display NaN as 100%.
        let clamped = fraction.isNaN ? 0 : max(0, min(1, fraction))
        return String(format: "%.0f%%", clamped * 100)
    }
}
