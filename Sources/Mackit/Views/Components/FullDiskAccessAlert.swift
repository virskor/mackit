import SwiftUI

/// Inline alert for a feature gated by Full Disk Access, with a button that
/// opens System Settings straight at the row.
///
/// Every permission-gated feature needs the same guidance — what cannot be
/// read, which permission unlocks it, and a jump to the exact settings row —
/// so the treatment (warning icon, tint, the jump and its label) lives here
/// once; a caller supplies only what *its* feature cannot do without the
/// permission and what to do after granting it. Built on `NoticeRow`, the
/// same row the confirmation sheet's warnings use, so an alert and those
/// warnings share one geometry instead of a second banner layout.
///
/// The copy must not spell out the click path through the settings tree: the
/// button does the walking, and the path ages the moment macOS moves the row.
struct FullDiskAccessAlert: View {
    /// What the feature cannot do without the permission — "Cannot read the
    /// apps' last-used times", not the generic "Permission required".
    let title: String
    /// The permission and what to do after granting it.
    let message: String

    var body: some View {
        NoticeRow(
            systemImage: "exclamationmark.triangle.fill",
            tint: .orange,
            title: title,
            message: message,
            action: (
                L10n.tr("permission.openSettings"),
                { SystemSettings.openFullDiskAccess() }
            ),
            actionHelp: L10n.tr("permission.openSettings.help")
        )
    }
}
