import SwiftUI

/// The large-file clean confirmation sheet.
///
/// A view of its own, like the other tools' sheets: every figure below is a
/// computed property read inside the body, so the sheet is live — the list,
/// the summary and the notices all follow the selection. The skeleton (title,
/// list, buttons, frame) is `ConfirmSheetShell`, shared with the cleanup
/// scan's and the app uninstall tool's sheets; what lives here is the
/// large-file copy and notices.
///
/// The risk notice is unconditional: every entry is a file the user picked by
/// size alone, and a large file is as likely to be a VM image, a database or
/// a project directory as it is to be a stale download — there is no per-item
/// risk to vary the wording by, so the sheet says "may hold your data" for
/// all of them.
struct LargeFilesConfirmSheet: View {
    @Environment(AppViewModel.self) private var vm

    private var model: LargeFilesModel { vm.largeFiles }

    /// Largest first, the order the shell lists in.
    private var items: [JunkItem] {
        model.selectedFiles
            .sorted { $0.size > $1.size }
            .map { model.junkItem(for: $0) }
    }

    /// The shared move-to-Trash setting, read live so a change in Settings
    /// shows up the next time the sheet opens.
    private var useTrash: Bool { vm.moveToTrash }

    var body: some View {
        ConfirmSheetShell(
            systemImage: "doc.fill",
            tint: .accentColor,
            title: L10n.tr("largeFiles.confirm.title"),
            summary: L10n.fmt(
                "largeFiles.confirm.summary.\(items.count == 1 ? "one" : "other")",
                items.count,
                Formatters.bytes(model.selectedSize)
            ),
            items: items,
            notices: {
                // The review-level risk notice, with the large-file wording:
                // what these files might be, and what losing them would mean.
                NoticeRow(
                    systemImage: "exclamationmark.circle.fill",
                    tint: .orange,
                    title: L10n.tr("clean.confirm.reviewTitle"),
                    message: L10n.tr("largeFiles.confirm.reviewMessage")
                )
                .padding(.top, 14)

                // Clean method, read live from the shared setting.
                NoticeRow(
                    systemImage: useTrash ? "trash" : "bolt.fill",
                    message: useTrash
                        ? L10n.tr("clean.confirm.toTrash")
                        : L10n.tr("clean.confirm.permanent")
                )
                .padding(.top, 12)
            },
            // The confirm button names the method, and turns red only for the
            // irreversible one — moving to the Trash is recoverable, and
            // painting it like a permanent delete would overstate it.
            confirmTitle: useTrash
                ? L10n.tr("largeFiles.confirm.action.trash")
                : L10n.tr("largeFiles.confirm.action.delete"),
            confirmTint: useTrash ? .accentColor : .red,
            onConfirm: { model.beginClean(moveToTrash: useTrash) },
            onCancel: { model.cancelConfirmation() }
        )
    }
}
