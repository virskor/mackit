import Foundation

/// The core entry point for localization lookup. All user-facing text goes through here,
/// with the actual strings in `Resources/Localizable.xcstrings` (String Catalog): the
/// source language is Simplified Chinese, plus English and Traditional Chinese
/// translations.
///
/// The whole tool only provides lookup and formatting: the engine and monitoring layers
/// use Foundation alone, and SwiftUI is not dragged in here.
///
/// Why not SwiftUI's `Text("literal")` / `Text("key \(value)")`: those two paths hand
/// lookup to `Bundle.main`, whereas this project's catalog is compiled into
/// `Bundle.module`, so only the key itself could be resolved.
///
/// Placeholder conventions match the String Catalog extraction rules: integers use
/// `%lld`, strings use `%@`. Word order can be adjusted during translation, and callers
/// pass `Int` / `String` in order.
enum L10n {
    /// Static key lookup, e.g. `L10n.tr("common.cancel")`.
    static func tr(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .module)
    }

    /// Lookup of a format string with placeholders, e.g. `L10n.fmt("toast.reclaimed", "1.2 GB")`.
    ///
    /// The two singular/plural keys (`.one` / `.other`) must keep the same placeholder
    /// layout: `.one` must also contain `%lld`, only swapping the noun for its singular
    /// form. Otherwise, when the caller passes arguments in the same order, `.one`'s
    /// `%@` would receive an integer, and CFString would dereference the integer as an
    /// object pointer and crash (address 0x1).
    static func fmt(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), arguments: args)
    }

    /// Count phrases like "N items"; singular/plural already handled per the current language.
    static func items(_ count: Int) -> String {
        String(format: tr(count == 1 ? "count.items.one" : "count.items.other"), count)
    }
}
