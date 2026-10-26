import SwiftUI

/// The uninstall confirmation sheet.
///
/// A view of its own, like the cleanup scan's `CleanConfirmationView`: every
/// figure below is a computed property read inside the body, so the sheet is
/// live — the leftover catch-up's "Select all" adds files to the selection,
/// and the list, the summary and the warnings all follow. Freezing them into
/// locals captured when the sheet opened would leave the sheet promising one
/// list while the clean deletes another.
///
/// The sheet holds no state of its own; show and dismiss are both driven by
/// the model's phase, avoiding the problem of "after cancel, the phase gets
/// stuck at .confirming, so clicking again doesn't pop up the sheet".
///
/// The skeleton (title, list, buttons, frame) is `ConfirmSheetShell`, shared
/// with the cleanup scan's sheet; what lives here is the uninstall-specific
/// copy and notices.
struct AppUninstallConfirmSheet: View {
    @Environment(AppViewModel.self) private var vm

    private var model: AppUninstallModel { vm.appUninstall }

    /// Sorted by size from large to small, largest first for easy verification.
    private var items: [JunkItem] { model.selectedItems.sorted { $0.size > $1.size } }
    private var hasCaution: Bool { items.contains { $0.risk == .caution } }
    /// Review-level entries: app support, preferences, containers and other
    /// places that may hold user data. The notice is the generic "re-
    /// downloaded or rebuilt" wording, which is what deleting them means.
    private var hasOtherReview: Bool { items.contains { $0.risk == .review } }
    private var runningApps: [String] { model.runningAppNames }
    /// Apps whose bundle is checked but whose leftover files aren't all
    /// checked yet.
    private var leftovers: [AppResidueSummary] { model.unselectedResidues }
    private var leftoverCount: Int { leftovers.reduce(0) { $0 + $1.count } }
    private var leftoverSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    /// Whether the selection includes app bundles. Uninstalling apps and only
    /// sweeping leftover files are different promises, and the copy has to
    /// say which one is about to happen: "Clean leftover files only" checks
    /// no bundle at all.
    private var isUninstall: Bool { model.selectedAppCount > 0 }
    /// The shared move-to-Trash setting, read live so a change in Settings
    /// shows up the next time the sheet opens.
    private var useTrash: Bool { vm.moveToTrash }

    var body: some View {
        ConfirmSheetShell(
            systemImage: hasCaution ? "exclamationmark.triangle.fill" : "trash.fill",
            tint: hasCaution ? .red : .accentColor,
            title: isUninstall
                ? L10n.tr("apps.confirm.title")
                : L10n.tr("clean.confirm.title"),
            // The uninstall copy counts by how many apps are being
            // uninstalled; residue file rows don't count — otherwise
            // "About to uninstall 1 app" would show 13.
            summary: L10n.fmt(
                isUninstall
                    ? (model.selectedAppCount == 1
                        ? "apps.confirm.summary.one"
                        : "apps.confirm.summary.other")
                    : (items.count == 1
                        ? "clean.confirm.summary.one"
                        : "clean.confirm.summary.other"),
                isUninstall ? model.selectedAppCount : items.count,
                Formatters.bytes(model.selectedSize)
            ),
            items: items,
            iconFor: { icon(for: $0) },
            notices: {
                // Running apps are skipped by the clean engine; listing them up
                // front avoids a wasted trip
                if !runningApps.isEmpty {
                    NoticeRow(
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange,
                        title: L10n.fmt(
                            runningApps.count == 1
                                ? "apps.confirm.running.one"
                                : "apps.confirm.running.other",
                            runningApps.count
                        ),
                        message: runningApps.joined(separator: ", ")
                    )
                    .padding(.top, 14)
                }

                // Only the app bundle is checked: caches, Application Support and
                // such files would be silently left behind; list the totals here
                // and offer a "Select All" one-tap catch-up
                if !leftovers.isEmpty {
                    NoticeRow(
                        systemImage: "folder.badge.questionmark",
                        tint: .orange,
                        title: L10n.tr("apps.confirm.leftoverTitle"),
                        message: L10n.fmt(
                            "apps.confirm.leftoverDetail",
                            leftoverNames(leftovers.map(\.appName)), leftoverCount, Formatters.bytes(leftoverSize)
                        ),
                        action: (
                            L10n.tr("apps.confirm.leftoverAction"),
                            { model.selectResiduesForSelectedApps() }
                        )
                    )
                    .padding(.top, 12)
                }

                // Risk notice
                if hasCaution {
                    NoticeRow(
                        systemImage: "exclamationmark.octagon.fill",
                        tint: .red,
                        title: L10n.tr("clean.confirm.cautionTitle"),
                        message: L10n.tr("clean.confirm.cautionMessage")
                    )
                    .padding(.top, 14)
                } else if hasOtherReview {
                    NoticeRow(
                        systemImage: "exclamationmark.circle.fill",
                        tint: .orange,
                        title: L10n.tr("clean.confirm.reviewTitle"),
                        message: L10n.tr("clean.confirm.reviewMessage")
                    )
                    .padding(.top, 14)
                }

                // Uninstall behavior note
                if isUninstall {
                    NoticeRow(
                        systemImage: "info.circle.fill",
                        tint: .accentColor,
                        message: L10n.tr("apps.confirm.note")
                    )
                    .padding(.top, 12)
                }

                // Clean method
                NoticeRow(
                    systemImage: useTrash ? "trash" : "bolt.fill",
                    message: useTrash
                        ? L10n.tr("clean.confirm.toTrash")
                        : L10n.tr("clean.confirm.permanent")
                )
                .padding(.top, 12)
            },
            confirmTitle: isUninstall
                ? L10n.tr("clean.confirm.uninstall")
                : (hasCaution
                    ? L10n.tr("clean.confirm.cleanAnyway")
                    : L10n.tr("clean.confirm.cleanNow")),
            confirmTint: isUninstall || hasCaution ? .red : .accentColor,
            onConfirm: { model.beginClean(moveToTrash: useTrash) },
            onCancel: { model.cancelConfirmation() }
        )
    }

    /// The real icon for an app bundle; nil for residue rows, which fall
    /// back to the category symbol.
    private func icon(for item: JunkItem) -> NSImage? {
        guard item.appKind == .bundle else { return nil }
        return model.icon(forPath: item.path)
    }

    /// List of app names with missed leftover files; when more than three,
    /// fold into "and N more apps".
    private func leftoverNames(_ names: [String]) -> String {
        let shown = ListFormatter.localizedString(byJoining: Array(names.prefix(3)))
        // The fold indicates the number not yet listed, not the total
        let more = names.count - 3
        guard more > 0 else { return shown }
        return shown + " " + L10n.fmt(
            more == 1 ? "apps.confirm.leftoverMore.one" : "apps.confirm.leftoverMore.other",
            more
        )
    }
}
