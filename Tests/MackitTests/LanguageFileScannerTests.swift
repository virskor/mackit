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
        languages: [String]
    ) throws {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
        ]
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
    }

    @Test func findsRemovableLanguageDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-lproj-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try makeApp(at: root, name: "Foo", bundleID: "com.example.foo",
                    languages: ["en", "zh-Hans", "Base", "ja", "fr"])

        let found = LanguageFileScanner.scanLanguageFiles(roots: [root.path])

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

        let found = LanguageFileScanner.scanLanguageFiles(roots: [root.path])
        #expect(found.isEmpty)
    }

    @Test func returnsEmptyForMissingRoot() {
        let found = LanguageFileScanner.scanLanguageFiles(roots: ["/definitely/not/a/real/path"])
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

        let found = LanguageFileScanner.scanLanguageFiles(roots: [root.path])
        #expect(found.count == 3)
        // Sorted by app name then language: Alpha's two packs stay adjacent
        // (detail is the localized "bundled inside <app>" string)
        #expect(found[0].detail.contains("Alpha"))
        #expect(found[1].detail.contains("Alpha"))
        #expect(found[2].detail.contains("Beta"))
        #expect(found.map(\.title) == ["ja.lproj", "ko.lproj", "fr.lproj"])
    }
}
