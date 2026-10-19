import Foundation

/// Discovery of old installers and archives sitting in the Downloads folder.
///
/// Dynamic rather than a static rule table for the same reason as
/// `LanguageFileScanner`: one glob per extension would flood the catalog, and
/// the extension sets are easier to maintain in one place here. Downloads is
/// user content, so every item is `.caution` — never auto-checked, and the
/// confirmation sheet always asks before deleting.
enum DownloadsScanner {
    /// Rule id for installer packages (disk images, installers, app archives).
    static let installerRuleID = "downloads.installer"
    /// Rule id for compressed archives.
    static let archiveRuleID = "downloads.archive"

    /// Installer-like extensions. `.ipa` is included because it is an app
    /// archive, not user data.
    static let installerExtensions: Set<String> = ["dmg", "iso", "pkg", "ipa"]

    /// Archive extensions. Compound suffixes (`.tar.gz`) surface as the final
    /// component (`gz`), which is what `URL.pathExtension` reports.
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "tgz", "gz", "bz2", "xz"]

    /// Scan the top level of `~/Downloads` for installer and archive files.
    ///
    /// Only the top level is scanned: installers land there directly, and a
    /// recursive walk of a user directory risks surfacing files the user has
    /// deliberately organized into subfolders. Directories are skipped.
    static func scanDownloads(home: String = NSHomeDirectory()) -> [JunkItem] {
        let downloads = (home as NSString).appendingPathComponent("Downloads")
        var found: [JunkItem] = []

        for child in FileSystem.children(of: downloads) {
            guard !FileSystem.isDirectory(child) else { continue }
            let ext = child.pathExtension.lowercased()
            let ruleID: String
            if installerExtensions.contains(ext) {
                ruleID = installerRuleID
            } else if archiveExtensions.contains(ext) {
                ruleID = archiveRuleID
            } else {
                continue
            }
            found.append(
                JunkItem(
                    ruleID: ruleID,
                    title: child.lastPathComponent,
                    detail: L10n.tr(ruleID == installerRuleID ? "downloads.installer.detail" : "downloads.archive.detail"),
                    path: child.path,
                    category: .downloads,
                    risk: .caution,
                    isDirectory: false
                )
            )
        }

        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
