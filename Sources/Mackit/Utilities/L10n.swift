import Foundation

/// The core entry point for localization lookup. All user-facing text goes through here,
/// with the actual strings in `Resources/Localizable.xcstrings` (String Catalog): the
/// source language is Simplified Chinese, plus English, Traditional Chinese, Korean
/// and Japanese translations.
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
    /// The plural keys of a family (`.one` / `.few` / `.many` / `.other`) must keep
    /// the same placeholder layout: `.one` must also contain `%lld`, only swapping
    /// the noun for its singular form. Otherwise, when the caller passes arguments
    /// in the same order, `.one`'s `%@` would receive an integer, and CFString would
    /// dereference the integer as an object pointer and crash (address 0x1).
    static func fmt(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), arguments: args)
    }

    /// The format string of a count phrase, with the form chosen for the language
    /// the process actually runs in, e.g.
    /// `L10n.fmt(L10n.plural("count.items", count), count)`.
    ///
    /// It resolves a format string instead of the formatted text because the count
    /// is not always the first argument: `toast.reclaimedWithFailures` passes the
    /// reclaimed size ahead of it. Callers keep their own argument order.
    ///
    /// The key family must carry a form for every category the running language can
    /// select — `.one` / `.few` / `.many` / `.other`, all sharing one placeholder
    /// layout — or the lookup degrades to the key itself. A language that does not
    /// distinguish a category carries the `.other` spelling under that key.
    static func plural(_ base: String, _ count: Int) -> String {
        tr("\(base).\(pluralCategory(count, for: AppLanguage.running))")
    }

    /// Count phrases like "N items"; singular/plural already handled per the current language.
    static func items(_ count: Int) -> String {
        String(format: plural("count.items", count), count)
    }

    /// The CLDR plural category `count` falls into, for a language Mackit ships.
    ///
    /// Only the languages that actually need a category are special-cased; every
    /// other shipped language selects between one and other on `count == 1`, which
    /// is the rule each call site hand-rolled before this existed. Russian is why
    /// this is a function and not a ternary: it has three integer forms, and a
    /// two-form model renders "2 файлов" where Russian wants "2 файла". French
    /// counts zero with the singular, matching CLDR and Apple's own UI.
    static func pluralCategory(_ count: Int, for language: AppLanguage) -> String {
        switch language {
        case .ru:
            let ones = count % 10
            let tens = count % 100
            if ones == 1 && tens != 11 { return "one" }
            if (2...4).contains(ones) && !(12...14).contains(tens) { return "few" }
            return "many"
        case .fr:
            return count <= 1 ? "one" : "other"
        default:
            return count == 1 ? "one" : "other"
        }
    }
}
