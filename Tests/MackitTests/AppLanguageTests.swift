import Foundation
import Testing

@testable import Mackit

/// Unit tests for language selection.
///
/// Covers three kinds of logic: persistence round-trip (including
/// AppleLanguages syncing), the matching rules for system preferences, and
/// the reachability of keys newly used by the settings page in the catalog.
/// Taking effect after a switch depends on CFBundle resolution at the next
/// launch, which is covered by manual verification (see AppLanguage's
/// comment: write AppleLanguages → restart → the UI follows).
///
/// The persistence cases each use a brand-new domain, but their `suite()`
/// helper deletes every leftover `AppLanguageTests.*` preferences file —
/// running them in parallel would let one case's cleanup unlink a live
/// case's not-yet-flushed plist. The suite is therefore `.serialized`;
/// on a plain test function the trait has no effect (it only orders the
/// cases of a parameterized test), which is why it sits here and not on
/// the five tests that need it. The app's real preferences (the standard
/// domain) are never touched.
@Suite(.serialized)
struct AppLanguageTests {
    /// A brand-new UserDefaults domain, along with the domain name (for
    /// asserting this domain's snapshot).
    ///
    /// The domain name carries a UUID: CFPreferences domains have on-disk
    /// files and a cfprefsd cache, so reusing a fixed domain name makes
    /// values left by the previous case/last run get lazily loaded back
    /// (removePersistentDomain does not delete files, which in practice does
    /// not block this cross-contamination); a brand-new domain name has no
    /// old values to begin with.
    private func suite() -> (UserDefaults, String) {
        let name = "AppLanguageTests.\(UUID().uuidString)"
        let prefs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        // Domain files do not disappear with removePersistentDomain, so each
        // test run leaves a pile of empty shells; clean up the last run's
        // leftovers here in passing.
        if let files = try? FileManager.default.contentsOfDirectory(at: prefs, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("AppLanguageTests.") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: - Persistence

    @Test func storedDefaultsToSystemWhenNothingRecorded() {
        let (defaults, _) = suite()
        #expect(AppLanguage.stored(in: defaults) == .system)
    }

    @Test func storedRoundTripsEveryLanguage() {
        let (defaults, _) = suite()
        // Every concrete language (`.system` excluded: it clears the keys)
        for language in AppLanguage.allCases where language != .system {
            AppLanguage.store(language, in: defaults)
            #expect(AppLanguage.stored(in: defaults) == language)
        }
    }

    @Test func storeSyncsAppleLanguagesForNextLaunch() {
        let (defaults, _) = suite()
        AppLanguage.store(.zhHant, in: defaults)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hant"])
    }

    @Test func storeSystemRemovesBothKeys() {
        let (defaults, name) = suite()
        AppLanguage.store(.en, in: defaults)
        AppLanguage.store(.system, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .system)
        // Look only at this domain's snapshot: after an override removal a
        // normal read falls through to the global domain and gets the system
        // language (["zh-Hans-HK", ...]), which is the behavior "Follow
        // System" wants and cannot be used for assertions; both keys must
        // already be gone from this domain.
        let domain = defaults.persistentDomain(forName: name) ?? [:]
        #expect(domain[AppLanguage.defaultsKey] == nil)
        #expect(domain["AppleLanguages"] == nil)
    }

    @Test func unknownStoredValueFallsBackToSystem() {
        let (defaults, _) = suite()
        defaults.set("kl", forKey: AppLanguage.defaultsKey)
        #expect(AppLanguage.stored(in: defaults) == .system)
    }

    // MARK: - System preference matching

    @Test func systemPreferredMatchesScriptBeforeRegion() {
        // The script subtag takes priority over the region: "zh-Hans-HK" is
        // Simplified even though the region is Hong Kong.
        #expect(AppLanguage.systemPreferred(languages: ["zh-Hans-HK", "en-HK"]) == .zhHans)
        #expect(AppLanguage.systemPreferred(languages: ["zh-Hant-HK", "en"]) == .zhHant)
    }

    @Test func systemPreferredMatchesRegionTags() {
        #expect(AppLanguage.systemPreferred(languages: ["zh-TW"]) == .zhHant)
        #expect(AppLanguage.systemPreferred(languages: ["zh-MO"]) == .zhHant)
        #expect(AppLanguage.systemPreferred(languages: ["zh", "en"]) == .zhHans)
        #expect(AppLanguage.systemPreferred(languages: ["zh-CN"]) == .zhHans)
    }

    @Test func systemPreferredTakesFirstSupportedLanguage() {
        // Japanese and Korean are supported now, so the first entry wins
        #expect(AppLanguage.systemPreferred(languages: ["ja-JP", "en-US", "zh-Hans"]) == .ja)
        #expect(AppLanguage.systemPreferred(languages: ["ko-KR", "en-US"]) == .ko)
        // A language the app does not ship is skipped, not fallen back to
        #expect(AppLanguage.systemPreferred(languages: ["fr-FR", "en-US"]) == .en)
    }

    @Test func systemPreferredFallsBackToSourceLanguage() {
        #expect(AppLanguage.systemPreferred(languages: ["fr-FR", "de-DE"]) == .zhHans)
        #expect(AppLanguage.systemPreferred(languages: []) == .zhHans)
    }

    // MARK: - Effective language

    @Test func effectiveResolvesSystemToConcreteLanguage() {
        #expect(AppLanguage.en.effective == .en)
        #expect(AppLanguage.zhHant.effective == .zhHant)
        #expect(AppLanguage.ko.effective == .ko)
        #expect(AppLanguage.ja.effective == .ja)
        // "Follow System" must resolve to one of the built-in languages and
        // cannot stop at the relay state.
        #expect(AppLanguage.system.effective != .system)
        #expect(AppLanguage.allCases.contains(AppLanguage.system.effective))
    }

    // MARK: - Display name

    @Test func concreteLanguagesUseNativeNames() {
        #expect(AppLanguage.zhHans.displayName == "简体中文")
        #expect(AppLanguage.en.displayName == "English")
        #expect(AppLanguage.zhHant.displayName == "繁體中文")
        #expect(AppLanguage.ko.displayName == "한국어")
        #expect(AppLanguage.ja.displayName == "日本語")
    }

    // MARK: - Localization key completeness

    /// On a lookup failure Foundation returns the key verbatim; use this to
    /// detect a missing translation.
    @Test func languageKeysResolveFromCatalog() {
        let keys = [
            "settings.language",
            "settings.language.system",
            "settings.language.restart",
            "settings.language.restartHint",
        ]
        for key in keys {
            #expect(L10n.tr(key) != key, "\(key) not localized")
        }
    }
}
