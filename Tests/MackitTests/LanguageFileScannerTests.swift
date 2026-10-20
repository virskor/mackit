import Foundation
import Testing

@testable import Mackit

struct LanguageFileScannerTests {
    /// Builds a fake app bundle with an Info.plist so `Bundle(url:)` reports a
    /// bundle ID, plus the given localization directories.
    private func makeApp(
        at root: URL,
        name: String,
        bundleID: String,
        languages: [String],
        developmentRegion: String? = nil
    ) throws {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
        ]
        if let developmentRegion { info["CFBundleDevelopmentRegion"] = developmentRegion }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        for language in languages {
            try FileManager.default.createDirectory(
                at: resources.appendingPathComponent("\(language).lproj", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func scan(
        at root: URL,
        preferredLanguages: [String] = ["zh-Hans", "en"]
    ) -> [JunkItem] {
        LanguageFileScanner.scanLanguageFiles(roots: [root.path], preferredLanguages: preferredLanguages)
    }

    @Test func whitelistKeepsChineseEnglishAndBase() {
        #expect(LanguageFileScanner.isWhitelisted("en"))
        #expect(LanguageFileScanner.isWhitelisted("Base"))
        #expect(LanguageFileScanner.isWhitelisted("zh-Hans"))
        #expect(LanguageFileScanner.isWhitelisted("zh-Hant"))
        // Chinese variants spelled differently by bundle authors are all kept
        #expect(LanguageFileScanner.isWhitelisted("zh-TW"))
        #expect(LanguageFileScanner.isWhitelisted("zh-Hans-CN"))
        #expect(!LanguageFileScanner.isWhitelisted("ja"))
        #expect(!LanguageFileScanner.isWhitelisted("fr"))
        #expect(!LanguageFileScanner.isWhitelisted("English"))
        // Separator and case are normalized: a directory spelled the way
        // Info.plist values are is still Chinese
        #expect(LanguageFileScanner.isWhitelisted("zh_CN"))
        #expect(LanguageFileScanner.isWhitelisted("base"))
    }

    @Test func findsRemovableLanguageDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root, name: "Foo", bundleID: "com.example.foo",
                    languages: ["en", "zh-Hans", "Base", "ja", "fr"])

        let found = scan(at: root)

        let titles = Set(found.map(\.title))
        #expect(titles == ["ja.lproj", "fr.lproj"])
        for item in found {
            #expect(item.ruleID == "language.lproj")
            #expect(item.category == .language)
            #expect(item.risk == .review)
            #expect(item.isDirectory)
            #expect(item.detail.contains("Foo"))
        }
    }

    @Test func skipsSystemAppsAndNonBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-skip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root, name: "Safari", bundleID: "com.apple.Safari",
                    languages: ["en", "ja", "fr"])
        // A directory that is not a bundle: no Info.plist, no bundle ID
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Broken.app/Contents/Resources/ja.lproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Plain directories are ignored as well
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ja.lproj", isDirectory: true),
            withIntermediateDirectories: true
        )

        let found = scan(at: root)
        #expect(found.isEmpty)
    }

    @Test func returnsEmptyForMissingRoot() {
        let found = LanguageFileScanner.scanLanguageFiles(
            roots: ["/definitely/not/a/real/path"], preferredLanguages: ["en"]
        )
        #expect(found.isEmpty)
    }

    @Test func groupsOneAppsLanguagesTogether() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-sort-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root, name: "Alpha", bundleID: "com.example.alpha",
                    languages: ["en", "ja", "ko"])
        try makeApp(at: root, name: "Beta", bundleID: "com.example.beta",
                    languages: ["en", "fr"])

        let found = scan(at: root)
        #expect(found.count == 3)
        // Sorted by app name then language: Alpha's two packs stay adjacent
        // (detail is the localized "bundled inside <app>" string)
        #expect(found[0].detail.contains("Alpha"))
        #expect(found[1].detail.contains("Alpha"))
        #expect(found[2].detail.contains("Beta"))
        #expect(found.map(\.title) == ["ja.lproj", "ko.lproj", "fr.lproj"])
    }

    // MARK: - Safety

    /// The crash the old whitelist caused: a Japanese-locale user's own
    /// interface language was proposed for deletion, so apps fell back to
    /// English — and apps that load a resource by name broke outright.
    @Test func systemLanguagesAreKept() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-system-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root, name: "Foo", bundleID: "com.example.foo",
                    languages: ["en", "Base", "ja", "ko"])

        // The system can select Japanese and Korean: neither may be removed
        let found = scan(at: root, preferredLanguages: ["ja-JP", "ko-KR", "en-US"])
        #expect(found.isEmpty, "system languages must never be cleaned: \(found.map(\.title))")
    }

    /// A region or script subtag says nothing about which language an
    /// interface ends up in, so "pt-BR" must protect "pt" and "fr_FR" must
    /// protect "fr" — bundle authors spell localizations both ways.
    @Test func languageMatchingIgnoresRegionAndSeparator() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-region-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root, name: "Foo", bundleID: "com.example.foo",
                    languages: ["en", "pt", "fr", "de"])

        let found = scan(at: root, preferredLanguages: ["pt-BR", "fr_FR"])
        #expect(Set(found.map(\.title)) == ["de.lproj"], "region / underscore spellings must also match by primary language")
    }

    /// `CFBundleDevelopmentRegion` is the fallback the system uses when none
    /// of the user's preferred languages are available; removing it can leave
    /// a bundle with no fallback at all.
    @Test func developmentRegionIsKept() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-devregion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root, name: "Foo", bundleID: "com.example.foo",
                    languages: ["en", "de"], developmentRegion: "de")

        let found = scan(at: root, preferredLanguages: ["en"])
        #expect(found.isEmpty, "the development region language must be kept: \(found.map(\.title))")
    }

    /// The last line of defense: a bundle whose every localization would be
    /// removed is left completely alone. With nothing to fall back to, an app
    /// that loads a resource by name crashes on launch instead of degrading
    /// to English.
    @Test func neverStripsTheLastLocalization() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-last-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A Japanese-only bundle with no English and no Base
        try makeApp(at: root, name: "Foo", bundleID: "com.example.foo",
                    languages: ["ja"])

        let found = scan(at: root, preferredLanguages: ["en"])
        #expect(found.isEmpty, "an app's language packs must not all be deleted")

        // The same bundle with an English fallback may lose Japanese
        try makeApp(at: root, name: "Bar", bundleID: "com.example.bar",
                    languages: ["ja", "en"])
        #expect(Set(scan(at: root, preferredLanguages: ["en"]).map(\.title)) == ["ja.lproj"])
    }

    /// Only whole `.lproj` directories are ever offered: deleting files
    /// *inside* one would invalidate the bundle's code seal (Apple seals
    /// localized resources as optional precisely so directories can be
    /// removed wholesale).
    @Test func onlyWholeLocalizationDirectoriesAreOffered() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-whole-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root, name: "Foo", bundleID: "com.example.foo",
                    languages: ["en", "ja", "fr"])
        // Files sitting next to the localizations are never touched, and a
        // nested resource inside a removable pack is not listed on its own
        let resources = root.appendingPathComponent("Foo.app/Contents/Resources", isDirectory: true)
        try Data("x".utf8).write(to: resources.appendingPathComponent("Assets.car"))
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent("ja.lproj/Localizable.strings", isDirectory: true),
            withIntermediateDirectories: true
        )

        let found = scan(at: root, preferredLanguages: ["en"])
        #expect(Set(found.map(\.title)) == ["ja.lproj", "fr.lproj"])
        #expect(found.allSatisfy { $0.path.hasSuffix(".lproj") }, "only whole language pack directories can be deleted")
        #expect(found.allSatisfy { $0.isDirectory })
    }

    /// Language packs carry their app's identity: the bundle ID feeds the
    /// running-app guard, and the display name is what the general page's
    /// per-language sub-rows and the confirmation list show.
    @Test func itemsCarryAppIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root, name: "Foo", bundleID: "com.example.foo",
                    languages: ["en", "ja"])

        let found = scan(at: root, preferredLanguages: ["en"])
        #expect(found.count == 1)
        #expect(found[0].bundleID == "com.example.foo")
        #expect(found[0].appName == "Foo")
        // Deleting an unused localization is safe even while the app runs:
        // the packs removed here are exactly the ones the system language
        // never selects.
        #expect(found[0].holdsLiveAppData == false)
    }

    /// An app whose display name differs from its bundle directory name is
    /// grouped and listed under the name the user recognizes.
    @Test func usesFinderDisplayNameForTheApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-display-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Foo.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.foo",
            "CFBundleDisplayName": "Fancy Foo",
            "CFBundleName": "Foo",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        for language in ["en", "ja"] {
            try FileManager.default.createDirectory(
                at: resources.appendingPathComponent("\(language).lproj", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        let found = scan(at: root, preferredLanguages: ["en"])
        #expect(found.count == 1)
        #expect(found[0].appName == "Fancy Foo")
        #expect(found[0].detail.contains("Fancy Foo"))
    }
}
