import SwiftUI
import AppKit

/// The startup-items tool page.
///
/// Lists every startup item the system exposes to a third-party app,
/// grouped by the app each one belongs to: per-user launch agents,
/// machine-wide agents, machine-wide daemons, and the legacy login-items
/// list. Each group carries the aggregate status and a master switch;
/// each entry carries its own switch and a reveal action.
///
/// Machine-wide daemons are the only entries that need more than the
/// app's own rights: their changes go through the privileged helper, so
/// the first such toggle opens the install sheet, and the helper's
/// state is shown above the list whenever daemons exist.
///
/// Every state-changing step is a switch the user flips: entering the
/// page scans once per session, and only the header's rescan
/// re-enumerates.
struct LoginItemsView: View {
    @Environment(AppViewModel.self) private var vm

    private var model: LoginItemsModel { vm.loginItems }

    /// Which groups are expanded to show their individual entries. View
    /// state: the expansion is presentation, not scan data.
    @State private var expandedIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // The content claims the rest of the card: without this the
            // list and the loading/empty states would size to their
            // content and the page would read as a thin strip floating
            // above an empty window — the same rule every other page
            // follows.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.windowBackground)
        .sheet(isPresented: Binding(
            get: { model.pendingChange != nil },
            set: { if !$0 { model.cancelPendingChange() } }
        )) {
            HelperInstallSheet()
                .environment(vm)
        }
        // Removing the privileged helper tears down root-owned files, so
        // the status card's action opens this confirmation first — the
        // same alert shape the Homebrew detail pane's uninstall confirm
        // uses.
        .alert(
            Text(verbatim: L10n.tr("loginItems.helper.removeConfirmTitle")),
            isPresented: Binding(
                get: { model.isConfirmingHelperRemoval },
                set: { if !$0 { model.cancelHelperRemoval() } }
            ),
            actions: {
                Button(L10n.tr("loginItems.helper.remove"), role: .destructive) {
                    model.removeHelper()
                }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            },
            message: {
                Text(verbatim: L10n.tr("loginItems.helper.removeConfirmMessage"))
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.tr("loginItems.title"))
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(.secondary)

                if model.hasScanned {
                    Text(verbatim: headerLine)
                        .font(Theme.Typography.pageTitle)
                        .lineLimit(1)
                } else if model.isLoading {
                    Text(verbatim: L10n.tr("scan.loginItems"))
                        .font(Theme.Typography.pageTitle)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            SearchField(
                text: Binding(
                    get: { model.searchText },
                    set: { model.searchText = $0 }
                ),
                placeholder: L10n.tr("loginItems.search")
            )
            .frame(minWidth: 120, maxWidth: 216)

            SegmentedBlock(
                items: LoginItemSort.allCases,
                title: { sort in
                    switch sort {
                    case .name: return L10n.tr("loginItems.sort.name")
                    case .status: return L10n.tr("loginItems.sort.status")
                    }
                },
                selection: Binding(
                    get: { model.sort },
                    set: { model.sort = $0 }
                )
            )
            .frame(width: 132)

            BrandCTAButton(
                title: model.isLoading
                    ? L10n.tr("loginItems.rescanning")
                    : L10n.tr("toolbar.rescan"),
                systemImage: "arrow.clockwise",
                style: .secondary,
                compact: true,
                showsProgress: model.isLoading
            ) {
                model.rescan()
            }
            .disabled(model.isLoading)
            .help(L10n.tr("loginItems.rescan.help"))
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// "12 个启动项 · 8 个已开启" — the total answers "is anything
    /// registered here", the enabled count how much of it actually runs.
    private var headerLine: String {
        let enabled = model.items.count { $0.isEnabled }
        return L10n.fmt("loginItems.count", model.items.count, enabled)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading, model.items.isEmpty {
            loadingState
        } else if model.items.isEmpty {
            emptyState(
                title: L10n.tr("loginItems.empty.title"),
                message: L10n.tr("loginItems.empty.message")
            )
        } else if model.visibleGroups.isEmpty {
            emptyState(
                title: L10n.tr("loginItems.noMatch.title"),
                message: L10n.tr("loginItems.noMatch.message")
            )
        } else {
            list
        }
    }

    /// The first scan's state: centered inside the full area, so it
    /// reads as the page's state rather than a strip pinned to the top.
    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(verbatim: L10n.tr("scan.loginItems"))
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(title: String, message: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "power",
            description: Text(verbatim: message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // The helper's state rides the top of the list whenever
                // daemons exist: it explains why some switches ask for a
                // password, and offers the remove action once installed.
                if model.hasSystemDaemons {
                    helperStatusCard
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }

                // The transient notice is a page-level alert too — the
                // same AlertCard the helper status wears, tinted by
                // severity, dismissed by its action. The glyph is
                // larger than the card's default because the message is
                // the card's only line: the icon carries the card's
                // weight on its own.
                if let notice = model.notice {
                    AlertCard(
                        systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle.fill",
                        tint: notice.isError ? Theme.Palette.danger : Theme.Palette.success,
                        iconSize: 15,
                        message: notice.message,
                        action: (L10n.tr("common.done"), { model.dismissNotice() })
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                ForEach(model.visibleGroups) { group in
                    LoginItemGroupRow(
                        group: group,
                        isExpanded: expandedIDs.contains(group.id),
                        icon: model.icon(forPath: group.iconPath ?? ""),
                        isRunning: group.items.contains { model.isRunning($0) },
                        onToggle: { enabled in
                            model.setGroupEnabled(group, enabled: enabled)
                        },
                        onExpand: { toggleExpanded(group) }
                    )

                    if expandedIDs.contains(group.id) {
                        entryRows(group)
                    }

                    Divider()
                        .padding(.leading, 46)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func entryRows(_ group: LoginItemGroup) -> some View {
        VStack(spacing: 0) {
            ForEach(group.items) { item in
                LoginItemEntryRow(
                    item: item,
                    isRunning: model.isRunning(item),
                    onToggle: { enabled in
                        model.toggle(item, enabled: enabled)
                    },
                    onReveal: {
                        reveal(item)
                    }
                )
            }
        }
    }

    // MARK: - Helper status

    /// The privileged helper's state, shown only when the list actually
    /// holds system daemons — a helper card on a machine with nothing
    /// for it to manage is noise. An `AlertCard`, the app's page-level
    /// alert: this is a standing statement about the page's own
    /// controls, not a row inside a list.
    private var helperStatusCard: some View {
        Group {
            switch model.helperState {
            case .installed(let version, let stale):
                AlertCard(
                    systemImage: VersionedSymbol.resolve("lock.shield.fill", fallback: "lock.fill"),
                    // A stale helper still works, but it predates the
                    // running app — the next system toggle replaces it.
                    tint: stale ? Theme.Palette.warning : Theme.Palette.success,
                    // The message is the card's only line, so the glyph
                    // carries its weight — larger than the card default.
                    iconSize: 15,
                    message: stale
                        ? L10n.fmt("loginItems.helper.installedStale", version)
                        : L10n.fmt("loginItems.helper.installed", version),
                    action: (L10n.tr("loginItems.helper.remove"), { model.requestHelperRemoval() })
                )
            case .notInstalled:
                AlertCard(
                    systemImage: VersionedSymbol.resolve("lock.shield", fallback: "lock.fill"),
                    tint: Theme.Palette.info,
                    iconSize: 15,
                    message: L10n.tr("loginItems.helper.notInstalled")
                )
            }
        }
    }

    // MARK: - Actions

    /// Reveals the file behind an item: its plist for agents and
    /// daemons, the target for a legacy login item.
    private func reveal(_ item: LoginItem) {
        let path = item.plistPath ?? item.targetPath ?? ""
        guard !path.isEmpty else { return }
        RevealInFinder.show(file: URL(fileURLWithPath: path))
    }

    private func toggleExpanded(_ group: LoginItemGroup) {
        if expandedIDs.contains(group.id) {
            expandedIDs.remove(group.id)
        } else {
            expandedIDs.insert(group.id)
        }
    }
}
