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

    /// Compact size with no space and fixed decimals, e.g. "206.53GB", "740.35MB".
    ///
    /// The disk analysis page's tiles and title follow the mockup's tighter
    /// style: `bytes` keeps a space and drops trailing zeros ("5 GB"), which
    /// reads too loose inside a treemap tile. Units are localized like
    /// `capacity`'s, but the unit itself carries no surrounding space.
    static func compactBytes(_ value: Int64) -> String {
        let gb = Double(value) / 1_000_000_000
        if gb >= 1000 { return Self.decimal(gb / 1000) + L10n.tr("format.terabytes.compact") }
        if gb >= 1 { return Self.decimal(gb) + L10n.tr("format.gigabytes.compact") }
        let mb = Double(value) / 1_000_000
        if mb >= 1 { return Self.decimal(mb) + L10n.tr("format.megabytes.compact") }
        let kb = Double(value) / 1000
        if kb >= 1 { return String(format: "%.1f", kb) + L10n.tr("format.kilobytes.compact") }
        return "\(value)" + L10n.tr("format.bytes.compact")
    }

    /// Two decimals, always shown: "5.00" reads as deliberate next to "206.53",
    /// whereas ByteCountFormatter's "5" makes tiles look inconsistent.
    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", value)
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

    /// Elapsed and remaining time as a clock: "m:ss", rolling over to "h:mm:ss"
    /// past an hour. Both readings come from a measurement whose total is only
    /// an estimate, so minutes and seconds carry the precision — a rounded
    /// "2 min" would claim an accuracy the estimate does not have. mm:ss reads
    /// the same in all three languages, so no unit words are needed.
    static func clock(_ duration: Duration) -> String {
        // A duration can go negative when the clock is read across a sleep
        // boundary; clamp rather than render "-1:-5".
        let seconds = max(0, duration.components.seconds)
        let hours = seconds / 3600
        let minutes = (seconds / 60) % 60
        let remainder = seconds % 60
        func padded(_ value: Int64) -> String { value < 10 ? "0\(value)" : "\(value)" }
        if hours > 0 { return "\(hours):\(padded(minutes)):\(padded(remainder))" }
        return "\(minutes):\(padded(remainder))"
    }
}
