import Foundation

/// Interface language. The app bundles five translations (see
/// `Resources/Localizable.xcstrings`), and the selection is written into the
/// app domain's `AppleLanguages`—CFBundle's string lookup reads this key,
/// resolves according to it after relaunch, and Sparkle's update UI and the
/// system file panels follow it as well.
///
/// Why not switch within the process: scan result titles and descriptions are fixed at
/// creation time according to the current language (see `JunkItem`'s comments); an
/// in-process refresh would only yield a list mixing old and new text, and notes such as
/// project relative paths, app version numbers, and residue counts do not even store the
/// original context, so they cannot be recomputed at all. A single relaunch keeps all the
/// text consistent, and is the least costly approach.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// Follow the system.
    case system
    /// Simplified Chinese (the catalog's source language).
    case zhHans = "zh-Hans"
    case en
    /// Traditional Chinese.
    case zhHant = "zh-Hant"
    /// Korean.
    case ko
    /// Japanese.
    case ja

    var id: String { rawValue }

    /// Display name in the picker. Every concrete language uses its own
    /// endonym (the convention in System Settings, so someone looking for
    /// their own language does not have to first understand the current
    /// language); "Follow system" goes through a localization key.
    var displayName: String {
        switch self {
        case .system: return L10n.tr("settings.language.system")
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .zhHant: return "繁體中文"
        case .ko: return "한국어"
        case .ja: return "日本語"
        }
    }

    /// Currently persisted selection; `.system` when nothing has been recorded.
    static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }

    /// Writes the selection and syncs `AppleLanguages`. `.system` means removing the
    /// override, returning to the system preference on next launch.
    static func store(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        if language == .system {
            defaults.removeObject(forKey: defaultsKey)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(language.rawValue, forKey: defaultsKey)
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// The language actually in effect for the selection: `.system` resolves per system
    /// preference, the others are themselves.
    var effective: AppLanguage {
        switch self {
        case .system: return Self.systemPreferred()
        default: return self
        }
    }

    /// The language currently in effect in the process: the `.lproj` chosen by CFBundle
    /// per `AppleLanguages`. Falls back to `.system` when it does not land on one of the
    /// five built-in languages.
    static var running: AppLanguage {
        guard let code = Bundle.module.preferredLocalizations.first,
              let language = AppLanguage(rawValue: code)
        else { return .system }
        return language
    }

    /// The first supported language in the system preference; falls back to the source
    /// language when none are supported.
    ///
    /// Matches on its own instead of using `Bundle.module.preferredLocalizations` directly:
    /// that property is unreliable in command-line and test processes (tested to always
    /// return `["en"]`), and the matching rules need to be unit-testable. The parameters
    /// can be injected, so tests can feed language identifiers directly.
    static func systemPreferred(languages: [String] = Locale.preferredLanguages) -> AppLanguage {
        for code in languages {
            let normalized = code.lowercased()
            guard normalized.hasPrefix("zh") || normalized.hasPrefix("en")
                || normalized.hasPrefix("ko") || normalized.hasPrefix("ja") else { continue }
            // Script subtags take priority over region: "zh-Hans-HK" is Simplified, "zh-Hant-TW" is Traditional.
            if normalized.contains("hans") { return .zhHans }
            if normalized.contains("hant")
                || normalized.hasSuffix("-tw")
                || normalized.hasSuffix("-hk")
                || normalized.hasSuffix("-mo") {
                return .zhHant
            }
            // Korean and Japanese carry no script subtag worth distinguishing, so the
            // primary subtag decides ("ko-KR" → Korean, "ja-JP" → Japanese).
            if normalized.hasPrefix("ko") { return .ko }
            if normalized.hasPrefix("ja") { return .ja }
            if normalized.hasPrefix("en") { return .en }
            // Bare "zh" and zh-CN / zh-SG: treated as Simplified.
            return .zhHans
        }
        return .zhHans
    }

    /// UserDefaults key. Internally visible so tests can inject an independent domain.
    static let defaultsKey = "appLanguage"
}
