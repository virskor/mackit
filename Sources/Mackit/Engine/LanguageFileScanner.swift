import Foundation

/// Discovery of useless localization directories inside installed app bundles.
///
/// Dynamic like `AppScanner`: the whitelist can't be expressed as a static
/// glob — a glob over `*.lproj` would also match the languages worth keeping
/// — so bundles are enumerated and filtered here. Discoveries take the same
/// path as app / project scanning: handed to the caller to have their sizes
/// filled in and merged into the list.
enum LanguageFileScanner {
    /// Rule id shared by all language-file items.
    static let ruleID = "language.lproj"

    /// Languages always kept: English, the unlocalized `Base` fallback every
    /// bundle carries, and Chinese in any variant (`zh-Hans`, `zh-Hant`,
    /// `zh-TW`, `zh-Hans-CN`, …) — the three UI languages Mackit itself ships.
    /// Chinese is matched by prefix rather than exact spelling because bundle
    /// authors pick different spellings, and dropping a Chinese variant would
    /// push those users onto English.
    static func isWhitelisted(_ language: String) -> Bool {
        language == "en" || language == "Base" || language.hasPrefix("zh-")
    }

    /// Discover removable `.lproj` directories under the given roots.
    ///
    /// `com.apple.*` bundles are skipped, consistent with `AppScanner`: they
    /// are system-managed, their localizations are already minimal, and their
    /// bundles sit closer to SIP where modifying contents is riskier.
    static func scanLanguageFiles(
        roots: [String] = ["/Applications", "~/Applications"]
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
                for lproj in FileSystem.children(of: resources.path) {
                    guard lproj.pathExtension.lowercased() == "lproj" else { continue }
                    let language = lproj.deletingPathExtension().lastPathComponent
                    guard !isWhitelisted(language) else { continue }
                    guard seenPaths.insert(lproj.path).inserted else { continue }
                    found.append(
                        JunkItem(
                            ruleID: ruleID,
                            title: lproj.lastPathComponent,
                            detail: L10n.fmt("language.item.detail", appName),
                            path: lproj.path,
                            category: .language,
                            risk: .review,
                            isDirectory: true
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
