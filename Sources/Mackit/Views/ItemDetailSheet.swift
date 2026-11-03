import SwiftUI

/// The detail sheet for one cleanable entry: what it is, where it lives, and
/// what clearing it does — opened by double-clicking a row in the item list
/// (or its context menu's "View Details").
///
/// A sheet rather than an inline expansion: the entry's full path, size and
/// modification date do not fit a table row, and the row's job is scanning a
/// long list, not reading one entry. Clearing goes through the same engine as
/// the toolbar's clean, at the scale of one entry (see
/// `AppViewModel.cleanSingle`), and asks first — a clean is destructive and
/// never runs on one click, the rule every clean in this app follows.
struct ItemDetailSheet: View {
    @Environment(AppViewModel.self) private var vm

    let item: JunkItem

    /// The clean confirmation.
    @State private var confirmsClean = false
    /// While the single-item clean runs: the action row swaps its buttons
    /// for a spinner so a long removal — a multi-gigabyte cache takes seconds
    /// to re-measure and delete — does not read as a frozen sheet.
    @State private var isCleaning = false
    /// The last failure, shown under the metadata: the sheet stays open so
    /// the entry — and the reason it survived — can be read.
    @State private var failureMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            metadata
            if let failureMessage {
                NoticeRow(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: L10n.tr("item.detail.failedTitle"),
                    message: failureMessage
                )
                .padding(.horizontal, 28)
                .padding(.top, 12)
            }
            Spacer(minLength: 14)
            actions
        }
        // The width is fixed and the height follows the content: the path
        // wraps to as many lines as it needs, and a fixed height would clip
        // the longest one.
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog(
            L10n.fmt("item.detail.cleanConfirmTitle", item.title),
            isPresented: $confirmsClean,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("clean.button"), role: .destructive) {
                Task { await clean() }
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            // The method is the user's own preference, stated here because
            // it decides whether the clean is recoverable.
            Text(verbatim: vm.moveToTrash
                ? L10n.tr("item.detail.cleanToTrash")
                : L10n.tr("item.detail.cleanPermanent"))
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CategoryIcon(category: item.category, size: 22, width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.category.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(verbatim: item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The full name is the one thing a truncated title owes
                    // the reader; the row's tooltip already does this.
                    .help(item.title)
            }

            Spacer(minLength: 12)

            RiskBadge(risk: item.risk)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            metadataRow(L10n.tr("table.size"), item.sizeText)
            metadataRow(L10n.tr("table.modified"), Formatters.relative(item.modified))
            metadataRow(L10n.tr("item.detail.category"), item.category.title)
            if !item.detail.isEmpty {
                metadataRow(L10n.tr("item.detail.source"), item.detail)
            }
            // A command-line entry has no path — its "where" is the command
            // itself, and a 路径 row would name something that does not
            // exist.
            metadataRow(
                item.isCommand ? L10n.tr("item.detail.command") : L10n.tr("item.detail.path"),
                item.displayPath
            )
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            // Selectable: a path is copied from here by hand at least as
            // often as through the button.
            Text(verbatim: value)
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        // Deliberately three actions plus close. The row is width-constrained
        // — a button truncates rather than wraps — and the long translations
        // (French "Afficher dans le Finder", Spanish "Mostrar en el Finder")
        // already take most of the sheet's 560pt. The context menu keeps the
        // rest of the item actions, one right-click away.
        HStack(spacing: 10) {
            if isCleaning {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: L10n.tr("item.detail.cleaning"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                // Accent-colored, the same as the toolbar's clean button.
                // No caution escalation here: every caution rule in the
                // catalog is general-scoped, and this sheet is reachable
                // only from the developer list, whose entries are safe or
                // review. The badge above still names the level.
                ProminentActionButton(title: L10n.tr("clean.button")) {
                    confirmsClean = true
                }
            }

            Button(L10n.tr("ctx.revealInFinder")) { vm.revealInFinder(item) }
                .disabled(item.path.isEmpty)
            Button(L10n.tr("ctx.copyPath")) { vm.copyPath(item) }

            Spacer(minLength: 8)

            Button(L10n.tr("common.close")) { vm.dismissItemDetail() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    // MARK: - Clean

    /// Runs the single-item clean and folds its outcome into the sheet: a
    /// success closes it (the entry leaves the list, and the sheet's binding
    /// resolves to nothing), a failure stays and says why.
    private func clean() async {
        isCleaning = true
        failureMessage = nil
        let outcome = await vm.cleanSingle(item)
        isCleaning = false
        if !outcome.succeeded {
            failureMessage = outcome.message
        }
    }
}
