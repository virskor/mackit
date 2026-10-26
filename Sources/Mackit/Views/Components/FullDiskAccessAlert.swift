import SwiftUI

/// The Full Disk Access alert: an `AlertCard` preset for every feature the
/// permission gates.
///
/// Permission-gated features all need the same guidance — what cannot be
/// read, which permission unlocks it, and a jump to the exact settings row —
/// so the treatment (warning icon, tint, the jump and its label) lives here
/// once; a caller supplies only what *its* feature cannot do without the
/// permission and what to do after granting it.
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
        AlertCard(
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
