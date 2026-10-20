import SwiftUI

/// Which of the two cleanup audiences a scan category belongs to.
///
/// Mackit serves two very different users with the same engine: developers
/// who want their toolchain caches gone, and everyone else who wants the
/// Lemon-style general junk sweep. Mixing both into one list makes each
/// audience wade through categories that mean nothing to them, so the main
/// window splits into two modes; the tray panel keeps reporting the grand
/// total across both, because its one-click clean deliberately sweeps
/// everything safe.
enum CleanupScope: String, CaseIterable, Identifiable, Sendable {
    /// Toolchain caches: Xcode, simulators, package managers, build artifacts.
    case developer
    /// General junk: browsers, language files, Downloads, system caches, Trash.
    case general

    var id: String { rawValue }

    /// Localization key prefix; the actual text lives in Localizable.xcstrings.
    private var key: String { "scope.\(rawValue)" }

    var title: String {
        L10n.tr("\(key).title")
    }

    /// One-line description of what this mode covers, shown as the picker's help.
    var summary: String {
        L10n.tr("\(key).summary")
    }

    /// Localization key of the "scanning…" title shown while a scan runs.
    /// The developer mode sweeps toolchain caches and the general mode sweeps
    /// junk, so each screen must announce its own subject rather than share
    /// one wording.
    var scanProgressTitleKey: String {
        switch self {
        case .developer: return "scan.progress.title"
        case .general: return "scan.progress.title.general"
        }
    }

    var symbol: String {
        switch self {
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .general: return "sparkles"
        }
    }
}
