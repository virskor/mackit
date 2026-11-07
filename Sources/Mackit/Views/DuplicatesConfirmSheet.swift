import SwiftUI

/// The duplicate-file clean confirmation sheet.
///
/// A view of its own, like the other tools' sheets: every figure below is a
/// computed property read inside the body, so the sheet is live — the list,
/// the summary and the notices all follow the selection. The skeleton (title,
/// list, buttons, frame) is `ConfirmSheetShell`, shared with the cleanup
/// scan's and the other tools' sheets; what lives here is the duplicate
/// copy and notices.
///
/// The risk notice is unconditional: every entry is a copy of content the
/// user is keeping at least one of, and the sheet says so rather than
/// guessing per file. On top of it, groups whose *every* copy is selected
/// are counted — that is the one selection that deletes content outright
/// (recoverable in the Trash, gone with the permanent-delete setting), so it
/// may not pass silently.
struct DuplicatesConfirmSheet: View {
    @Environment(AppViewModel.self) private var vm

    private var model: DuplicatesModel { vm.duplicates }

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
            systemImage: "doc.on.doc",
            tint: Theme.Palette.info,
            title: L10n.tr("duplicateFiles.confirm.title"),
            summary: L10n.fmt(
                L10n.plural("duplicateFiles.confirm.summary", items.count),
                items.count,
                Formatters.bytes(model.selectedSize)
            ),
            items: items,
            notices: {
                // The one selection that loses content outright, named
                // before the button.
                if model.groupsFullySelected > 0 {
                    NoticeRow(
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Theme.Palette.warning,
                        message: L10n.fmt(
                            L10n.plural("duplicateFiles.confirm.allCopies", model.groupsFullySelected),
                            model.groupsFullySelected
                        )
                    )
                    .padding(.top, 14)
                }

                // The review-level risk notice, with the duplicate wording:
                // what these files are, and what the keeper guarantees.
                NoticeRow(
                    systemImage: "exclamationmark.circle.fill",
                    tint: Theme.Palette.warning,
                    title: L10n.tr("clean.confirm.reviewTitle"),
                    message: L10n.tr("duplicateFiles.confirm.reviewMessage")
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
            // The confirm button names the method, and turns red only for
            // the irreversible one — moving to the Trash is recoverable, and
            // painting it like a permanent delete would overstate it.
            confirmTitle: useTrash
                ? L10n.tr("duplicateFiles.confirm.action.trash")
                : L10n.tr("duplicateFiles.confirm.action.delete"),
            confirmTint: useTrash ? Theme.Palette.info : Theme.Palette.danger,
            onConfirm: { model.beginClean(moveToTrash: useTrash) },
            onCancel: { model.cancelConfirmation() }
        )
    }
}
