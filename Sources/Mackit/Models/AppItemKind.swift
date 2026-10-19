import Foundation

/// Kinds of app-uninstall-related entries.
///
/// The app itself (.app) and its leftover files each appear as an independent row in the
/// table, but their behavior during uninstall differs: the app itself is protected by the
/// "app is running" check, while leftover files get their risk level and localized text
/// according to kind.
enum AppItemKind: Sendable, Hashable {
    /// The .app bundle itself.
    case bundle
    /// Associated files left in various places under ~/Library after the app is removed.
    case residue(ResidueKind)

    var isResidue: Bool {
        if case .residue = self { return true }
        return false
    }
}

/// Kinds of leftover files, each corresponding to a fixed location under ~/Library.
///
/// Pure cache types are rebuilt by the app itself after deletion, marked safe; the rest
/// may retain user data (preferences, window state, databases inside containers, etc.),
/// marked review.
enum ResidueKind: String, Sendable, Hashable, CaseIterable {
    case applicationSupport
    case caches
    case containers
    case preferences
    case savedState
    case httpStorages
    case webKit
    case cookies
    case applicationScripts
    case launchAgents
    case logs
    case crashReports
    case diagnosticReports

    /// Localization key fragment; the text lives in Localizable.xcstrings.
    var labelKey: String { "apps.residue.\(rawValue)" }

    var risk: RiskLevel {
        switch self {
        case .caches, .httpStorages, .webKit, .cookies, .logs, .crashReports, .diagnosticReports:
            return .safe
        case .applicationSupport, .containers, .preferences, .savedState,
             .applicationScripts, .launchAgents:
            return .review
        }
    }
}
