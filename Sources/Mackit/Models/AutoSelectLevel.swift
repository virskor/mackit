import Foundation

/// Auto-check tiers.
///
/// One tier more than RiskLevel—"no auto-checking": the other three tiers are the risk
/// ceiling for auto-checking, corresponding one-to-one with RiskLevel. This is a separate
/// enum rather than adding a case to RiskLevel, because RiskLevel describes the risk of
/// the entry itself (the badge, filtering, and the confirmation dialog all read it);
/// "no auto-checking" is not a kind of risk, and mixing it in would pollute those
/// semantics.
///
/// rawValue aligns with RiskLevel (none is -1, the rest are the same), so historical
/// values already stored in UserDefaults keep their original meaning.
enum AutoSelectLevel: Int, CaseIterable, Sendable {
    /// Do not auto-check any entry.
    case none = -1
    case safe = 0
    case review = 1
    case caution = 2

    /// Risk ceiling for the tier; none has no ceiling and returns nil.
    var riskCap: RiskLevel? {
        switch self {
        case .none: nil
        case .safe: .safe
        case .review: .review
        case .caution: .caution
        }
    }

    var title: String {
        guard let cap = riskCap else { return L10n.tr("settings.autoSelect.none") }
        return cap.title
    }
}
