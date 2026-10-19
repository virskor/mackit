import SwiftUI

/// Clean confirmation panel: before cleaning, the full list must be shown and
/// the user must explicitly confirm.
///
/// The panel itself holds no state; show and dismiss are both driven by
/// vm.cleanPhase, avoiding the problem of "after cancel, cleanPhase gets stuck
/// at .confirming, so clicking again doesn't pop up the panel".
struct CleanConfirmationView: View {
    @Environment(AppViewModel.self) private var vm

    /// The "remember this selection" prompt, on by default: the user just
    /// curated the general module's rows, and the common intent is to keep
    /// that curation. Reset on every presentation because the sheet builds
    /// its content fresh each time.
    @State private var rememberSelection = true

    /// Sorted by size from large to small, largest first for easy verification.
    private var items: [JunkItem] { vm.selectedItems.sorted { $0.size > $1.size } }
    private var hasCaution: Bool { items.contains { $0.risk == .caution } }
    private var hasReview: Bool { items.contains { $0.risk == .review } }
    /// When the selection includes app bundles, the whole panel switches to
    /// uninstall context.
    private var isUninstall: Bool { vm.hasSelectedApps }
    private var runningApps: [String] { vm.runningAppNames }
    /// Apps whose bundle is checked but whose associated files aren't all
    /// checked yet.
    private var leftovers: [AppResidueSummary] { vm.unselectedAppResidues }
    private var leftoverCount: Int { leftovers.reduce(0) { $0 + $1.count } }
    private var leftoverSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }

    /// List of app names with missed associated files; when more than three,
    /// fold into "and N more apps".
    private var leftoverNames: String {
        let names = leftovers.map(\.appName)
        let shown = ListFormatter.localizedString(byJoining: Array(names.prefix(3)))
        guard names.count > 3 else { return shown }
        // The fold indicates the number not yet listed, not the total
        return shown + " " + L10n.fmt("apps.confirm.leftoverMore", names.count - 3)
    }

    /// The number of app bundles among the selected items. The uninstall copy
    /// counts by how many apps are being uninstalled; residue file rows don't
    /// count — otherwise "About to uninstall 1 app" would show 13.
    private var bundleCount: Int {
        items.filter { $0.appKind == .bundle }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title area
            VStack(spacing: 12) {
                IconBadge(
                    systemImage: hasCaution ? "exclamationmark.triangle.fill" : "trash.fill",
                    tint: hasCaution ? .red : .accentColor,
                    diameter: 56,
                    symbolSize: 24
                )

                VStack(spacing: 5) {
                    Text(isUninstall ? L10n.tr("apps.confirm.title") : L10n.tr("clean.confirm.title"))
                        .font(.system(size: 17, weight: .bold))
                    Text(verbatim: L10n.fmt(
                        isUninstall
                            ? (bundleCount == 1
                                ? "apps.confirm.summary.one"
                                : "apps.confirm.summary.other")
                            : (items.count == 1
                                ? "clean.confirm.summary.one"
                                : "clean.confirm.summary.other"),
                        isUninstall ? bundleCount : items.count,
                        Formatters.bytes(vm.selectedSize)
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 18)

            // Item list: shows all checked items in full, no truncation
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(
                    title: L10n.tr("clean.confirm.list"),
                    trailing: L10n.fmt(
                        items.count == 1
                            ? "clean.confirm.listCount.one"
                            : "clean.confirm.listCount.other",
                        items.count
                    )
                )

                List(items) { item in
                    JunkItemRow(item: item, subtitle: item.abbreviatedPath, icon: vm.icon(for: item))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .padding(.horizontal, 20)

            // Running apps are skipped by the clean engine; listing them up
            // front avoids a wasted trip
            if isUninstall && !runningApps.isEmpty {
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
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            // Only the app bundle is checked: caches, Application Support and
            // such files would be silently left behind; list the totals here
            // and offer a "Select All" one-tap catch-up
            if isUninstall && !leftovers.isEmpty {
                NoticeRow(
                    systemImage: "folder.badge.questionmark",
                    tint: .orange,
                    title: L10n.tr("apps.confirm.leftoverTitle"),
                    message: L10n.fmt(
                        "apps.confirm.leftoverDetail",
                        leftoverNames, leftoverCount, Formatters.bytes(leftoverSize)
                    ),
                    action: (
                        L10n.tr("apps.confirm.leftoverAction"),
                        { vm.selectResiduesForSelectedApps() }
                    )
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            // Risk notice
            if hasCaution || hasReview {
                NoticeRow(
                    systemImage: hasCaution ? "exclamationmark.octagon.fill" : "exclamationmark.circle.fill",
                    tint: hasCaution ? .red : .orange,
                    title: hasCaution
                        ? L10n.tr("clean.confirm.cautionTitle")
                        : L10n.tr("clean.confirm.reviewTitle"),
                    message: hasCaution
                        ? L10n.tr("clean.confirm.cautionMessage")
                        : L10n.tr("clean.confirm.reviewMessage")
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            // Uninstall behavior note
            if isUninstall {
                NoticeRow(
                    systemImage: "info.circle.fill",
                    tint: .accentColor,
                    message: L10n.tr("apps.confirm.note")
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            // Clean method
            NoticeRow(
                systemImage: vm.moveToTrash ? "trash" : "bolt.fill",
                message: vm.moveToTrash
                    ? L10n.tr("clean.confirm.toTrash")
                    : L10n.tr("clean.confirm.permanent")
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // The user curated the general module's rows differently from
            // what the next scan would pre-check: offer to remember that
            // curation, defaulted to on so one click keeps it.
            if vm.showsRememberGeneralPrompt {
                rememberRow
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            Spacer(minLength: 16)

            // Buttons
            HStack(spacing: 10) {
                Button(L10n.tr("common.cancel")) { vm.cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)

                ProminentActionButton(
                    title: isUninstall
                        ? L10n.tr("clean.confirm.uninstall")
                        : (hasCaution
                            ? L10n.tr("clean.confirm.cleanAnyway")
                            : L10n.tr("clean.confirm.cleanNow")),
                    tint: isUninstall || hasCaution ? .red : .accentColor
                ) {
                    // Only when the prompt is actually showing: the toggle
                    // defaults to on, so without the guard every clean —
                    // including the developer module's and the tray's —
                    // would silently save a selection.
                    if rememberSelection && vm.showsRememberGeneralPrompt {
                        vm.rememberGeneralSelection()
                    }
                    vm.beginClean()
                }
            }
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The remember-this-selection row: an inline toggle rather than a
    /// NoticeRow, which only offers a one-shot action button.
    private var rememberRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: L10n.tr("general.remember.title"))
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: L10n.tr("general.remember.message"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle(isOn: $rememberSelection) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}
