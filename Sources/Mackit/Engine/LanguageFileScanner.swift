import Foundation

/// Discovery of useless localization directories inside installed app bundles.
///
/// Dynamic like `AppScanner`: the whitelist can't be expressed as a static
/// glob — a glob over `*.lproj` would also match the languages worth keeping
/// — so bundles are enumerated and filtered here. Discoveries take the same
/// path as app / project scanning: handed to the caller to have their sizes
/// filled in and merged into the list.
///
/// ## What is safe to remove
///
/// Only ever a whole `.lproj` directory, never files inside one. That
/// distinction is what keeps an app's code signature intact: Apple seals
/// localized resources as *optional* (verified: deleting an optional-sealed
/// `.lproj` leaves `codesign --verify` passing, while editing a sealed file
/// inside it invalidates the seal and can stop a hardened-runtime app from
/// launching at all).
///
/// Beyond that, five languages are always kept per bundle: `Base` and `en`
/// (the universal fallbacks), every Chinese variant plus `ko` and `ja`
/// (Mackit's own UI languages), the languages the system can select —
/// including the one a single app was given — and the bundle's development
/// region. And a bundle is never stripped of its *last* localization — with
/// nothing left to fall back to, an app that loads a resource by name
/// crashes on launch instead of degrading to English.
enum LanguageFileScanner {
    /// Rule id shared by all language-file items.
    static let ruleID = "language.lproj"

    /// Languages always kept: English, the unlocalized `Base` fallback every
    /// bundle carries, and Chinese, Korean and Japanese in any variant
    /// (`zh-Hans`, `zh-Hant`, `zh-TW`, `zh-Hans-CN`, `ko-KR`, `ja-JP`, …) —
    /// the five UI languages Mackit itself ships.
    ///
    /// The keep-set is the whole shipped set, not just the language currently
    /// selected: whoever runs Mackit reads at least one of them, and stripping
    /// the rest out of every other app would hit a Korean-reading user exactly
    /// like the Japanese-locale case described on `isSystemLanguage`.
    ///
    /// English, Chinese, Korean and Japanese are matched by primary subtag,
    /// not by exact spelling: bundle authors ship `en-GB.lproj` and `en_US.lproj`
    /// just as often as `en.lproj`, and dropping the only English pack of such
    /// a bundle would break the "English is always kept" promise above while
    /// leaving nothing else for the app to fall back to.
    static func isWhitelisted(_ language: String) -> Bool {
        switch primarySubtag(language) {
        case "en", "zh", "ko", "ja", "base": return true
        default: return false
        }
    }

    /// The app's own language preference list, when it has one.
    ///
    /// `AppleLanguages` in an app's own preference domain pins that app to a
    /// language regardless of the system list — written by an in-app language
    /// picker, and by the per-app language setting in System Settings. Either
    /// way it is *not* part of `Locale.preferredLanguages`, so a scanner that
    /// only reads the system list treats the one localization that app is set
    /// to use as unused and deletes it; the app then silently reverts to the
    /// system language.
    ///
    /// Verified on this machine: `com.bot.pc.doubao` carries `zh_CN` and
    /// `asc.onlyoffice.ONLYOFFICE` carries `zh-ZH`, while the system list is
    /// `zh-Hans-HK / en-HK / ko-HK`. Both values come from the apps' own
    /// pickers; the Settings pane writes the same key, which is what this
    /// reads either way.
    static func appLanguages(for bundleID: String) -> [String] {
        // `CFPreferencesCopyAppValue` would be the obvious call, but it falls
        // back to the global domain and would therefore hand back the system
        // list again; copying the app's own value keeps this a real second
        // signal instead of a repeat of the first.
        let value = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            bundleID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return value as? [String] ?? []
    }

    /// The primary subtag of a language identifier: `zh-Hans-CN` → `zh`,
    /// `pt_BR` → `pt`. Bundle authors spell localizations with either
    /// separator, and a region or script subtag says nothing about which
    /// *language* an interface ends up in — matching on the primary subtag is
    /// what makes "the system is Japanese" protect `ja` regardless of
    /// spelling.
    static func primarySubtag(_ language: String) -> String {
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        return normalized.split(separator: "-").first.map { $0.lowercased() } ?? ""
    }

    /// Whether a localization is one the system can select: its primary
    /// subtag appears among the preferred languages.
    ///
    /// macOS resolves an app's interface language by walking the user's
    /// preferred list and taking the first localization the bundle has, so
    /// anything matching is either in use right now or one switch away.
    /// Removing it strips a language the user actually reads out of every app
    /// at once — the failure mode where a Japanese-locale user "cleaned" and
    /// found apps falling back to English.
    static func isSystemLanguage(_ language: String, preferredLanguages: [String]) -> Bool {
        let subtag = primarySubtag(language)
        guard !subtag.isEmpty else { return false }
        return preferredLanguages.contains { primarySubtag($0) == subtag }
    }

    /// Whether a localization is the bundle's declared development region.
    ///
    /// `CFBundleDevelopmentRegion` is the fallback the system uses when none
    /// of the user's preferred languages are available. Deleting it can leave
    /// a bundle with no fallback at all. The value is matched by primary
    /// subtag, so both the code spellings (`ja`, `zh_CN`) and the region-less
    /// ones are covered; the "English"/"Japanese" name spelling older bundles
    /// use is covered by the never-last-localization rule instead.
    static func isDevelopmentRegion(_ language: String, developmentRegion: String?) -> Bool {
        guard let developmentRegion, !developmentRegion.isEmpty else { return false }
        let subtag = primarySubtag(language)
        guard !subtag.isEmpty else { return false }
        return primarySubtag(developmentRegion) == subtag
    }

    /// Discover removable `.lproj` directories under the given roots.
    ///
    /// `com.apple.*` bundles are skipped, consistent with `AppScanner`: they
    /// are system-managed, their localizations are already minimal, and their
    /// bundles sit closer to SIP where modifying contents is riskier.
    ///
    /// `preferredLanguages` is injectable so tests can pin the "system"
    /// languages; the default is the real user preference list.
    /// `appLanguages` is injectable for the same reason: the per-app override
    /// lives in another app's preference domain, which the default closure
    /// reads and a test can stand in for.
    static func scanLanguageFiles(
        roots: [String] = ["/Applications", "~/Applications"],
        preferredLanguages: [String] = Locale.preferredLanguages,
        appLanguages: (String) -> [String] = LanguageFileScanner.appLanguages(for:)
    ) -> [JunkItem] {
        var found: [JunkItem] = []
        var seenPaths = Set<String>()

        for root in roots {
            for app in FileSystem.children(of: root) {
                guard app.pathExtension.lowercased() == "app" else { continue }
                guard let bundle = Bundle(url: app),
                      let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty,
                      !FileSystem.isSystemData(bundleID) else {
                    continue
                }
                let appName = displayName(of: bundle) ?? app.deletingPathExtension().lastPathComponent
                let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
                let localizations = FileSystem.children(of: resources.path)
                    .filter { $0.pathExtension.lowercased() == "lproj" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }

                let developmentRegion = bundle.infoDictionary?["CFBundleDevelopmentRegion"] as? String
                // The languages this app can be forced to load, on top of the
                // ones the system itself can select.
                let ownLanguages = appLanguages(bundleID)
                func isKept(_ lproj: URL) -> Bool {
                    let language = lproj.deletingPathExtension().lastPathComponent
                    return isWhitelisted(language)
                        || isSystemLanguage(language, preferredLanguages: preferredLanguages)
                        || isSystemLanguage(language, preferredLanguages: ownLanguages)
                        || isDevelopmentRegion(language, developmentRegion: developmentRegion)
                }

                let kept = localizations.filter(isKept)
                // Every localization is removable: the bundle would be left
                // with nothing to fall back to, so keep all of it.
                guard !kept.isEmpty else { continue }

                for lproj in localizations where !isKept(lproj) {
                    guard seenPaths.insert(lproj.path).inserted else { continue }
                    found.append(
                        JunkItem(
                            ruleID: ruleID,
                            title: lproj.lastPathComponent,
                            detail: L10n.fmt("language.item.detail", appName),
                            path: lproj.path,
                            category: .language,
                            risk: .review,
                            isDirectory: true,
                            bundleID: bundleID,
                            appName: appName,
                            // Not live data: the localizations removed here are
                            // exactly the ones the system language never
                            // selects, so no running process can be reading
                            // them. The clean engine therefore deletes them
                            // even while the app is open.
                            holdsLiveAppData: false
                        )
                    )
                }
            }
        }

        // Sorted by app name then language, so a single app's language packs
        // stay adjacent in the list (same natural-order comparison as app discovery).
        return found.sorted { lhs, rhs in
            switch lhs.detail.localizedStandardCompare(rhs.detail) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    /// The name shown in Finder: CFBundleDisplayName first, then CFBundleName.
    private static func displayName(of bundle: Bundle) -> String? {
        let info = bundle.infoDictionary ?? [:]
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = info[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }
}
