import Foundation
import Testing

@testable import Mackit

struct DownloadsScannerTests {
    private func makeDownloads(home: URL, files: [String], directories: [String] = []) throws -> URL {
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        for name in directories {
            try FileManager.default.createDirectory(
                at: downloads.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        for name in files {
            try "x".write(
                to: downloads.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        return downloads
    }

    @Test func groupsInstallersAndArchives() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-downloads-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDownloads(home: home, files: [
            "Xcode.dmg", "Tool.pkg", "App.ipa", "Backup.zip", "Old.rar", "Bundle.7z",
            "Source.tar.gz", "notes.txt", "photo.jpg",
        ])

        let found = DownloadsScanner.scanDownloads(home: home.path)

        let byTitle = Dictionary(uniqueKeysWithValues: found.map { ($0.title, $0) })
        #expect(Set(byTitle.keys) == [
            "Xcode.dmg", "Tool.pkg", "App.ipa", "Backup.zip", "Old.rar", "Bundle.7z", "Source.tar.gz",
        ])
        // Installer extensions vs archive extensions
        #expect(byTitle["Xcode.dmg"]?.ruleID == "downloads.installer")
        #expect(byTitle["Tool.pkg"]?.ruleID == "downloads.installer")
        #expect(byTitle["App.ipa"]?.ruleID == "downloads.installer")
        #expect(byTitle["Backup.zip"]?.ruleID == "downloads.archive")
        #expect(byTitle["Source.tar.gz"]?.ruleID == "downloads.archive")
        // User content: never auto-selected, always confirmed
        for item in found {
            #expect(item.category == .downloads)
            #expect(item.risk == .caution)
            #expect(item.risk.requiresExplicitConfirm)
            #expect(!item.isDirectory)
            #expect(item.path.contains("Downloads"))
        }
    }

    @Test func skipsDirectoriesAndUnrelatedFiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-downloads-skip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDownloads(
            home: home,
            files: ["keep.txt", "script.sh"],
            directories: ["Archive.zip.d", "some-folder"]
        )

        let found = DownloadsScanner.scanDownloads(home: home.path)
        #expect(found.isEmpty)
    }

    @Test func matchesExtensionsCaseInsensitively() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-downloads-case-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try makeDownloads(home: home, files: ["XCODE.DMG", "BACKUP.ZIP"])

        let found = DownloadsScanner.scanDownloads(home: home.path)
        #expect(Set(found.map(\.title)) == ["XCODE.DMG", "BACKUP.ZIP"])
        #expect(found.allSatisfy { $0.category == .downloads })
    }

    @Test func returnsEmptyForMissingDownloads() {
        let found = DownloadsScanner.scanDownloads(home: "/definitely/not/a/real/home")
        #expect(found.isEmpty)
    }
}
