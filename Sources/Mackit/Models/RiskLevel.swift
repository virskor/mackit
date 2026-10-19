import Foundation

/// Risk level, determining default checked state and whether extra confirmation is needed before cleanup.
enum RiskLevel: Int, CaseIterable, Comparable, Sendable {
    /// Pure cache, automatically rebuilt by the tool after deletion, no data loss.
    case safe = 0
    /// Possibly a historical artifact or an old-version dependency; deleting it requires re-downloading / re-building.
    case review = 1
    /// Contains content the user may still need (archives, backups, the Trash).
    case caution = 2

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Fragment name in the localization key; the actual text lives in Localizable.xcstrings.
    private var key: String {
        switch self {
        case .safe: return "safe"
        case .review: return "review"
        case .caution: return "caution"
        }
    }

    var title: String {
        L10n.tr("risk.\(key).title")
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.shield"
        case .review: return "exclamationmark.circle"
        case .caution: return "exclamationmark.triangle"
        }
    }

    var hint: String {
        L10n.tr("risk.\(key).hint")
    }

    /// The higher the risk level, the stronger the cleanup confirmation wording.
    var requiresExplicitConfirm: Bool { self >= .caution }
}
