import Foundation
import Testing

@testable import Mackit

struct DownloadsScannerTests {
    private func makeDownloads(home: URL, files: [String], directories: [String] = []) throws {
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

    /// A `~/Downloads` relocated to another volume through a link must still be
    /// scanned. The listing opens with `open(O_DIRECTORY)`, which follows the
    /// link — unlike Foundation's URL-based `contentsOfDirectory(at:)`, which
    /// refuses one — so the installers are found under the spelling the user
    /// configured. Pinned because swapping this listing would silently report a
    /// clean folder for a folder it never looked inside.
    @Test func followsASymlinkedDownloadsFolder() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackit-downloads-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // The real folder lives elsewhere; the home's Downloads is a link to it.
        let real = home.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try "x".write(to: real.appendingPathComponent("Xcode.dmg"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Downloads"),
            withDestinationURL: real
        )

        let found = DownloadsScanner.scanDownloads(home: home.path)

        #expect(found.map(\.title) == ["Xcode.dmg"], "a linked Downloads folder produced \(found.map(\.title))")
        // Reported as the user spelled the folder: the link is what they see.
        #expect(found.first?.path == home.appendingPathComponent("Downloads/Xcode.dmg").path)
    }
}
