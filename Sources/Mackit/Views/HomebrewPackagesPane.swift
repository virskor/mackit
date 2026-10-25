import SwiftUI

/// The installed-packages master–detail pane, shared by the "Installed" and
/// "Upgrade" sections (the difference is only which packages the list holds).
///
/// The layout follows the official Homebrew GUIs: a filterable list on the
/// left, the selected package's facts and actions on the right. Every action
/// shows the terminal command it runs next to the button, so the GUI is a
/// shortcut over the CLI rather than a replacement for it.
struct HomebrewPackagesPane: View {
    @Environment(AppViewModel.self) private var vm

    /// Which packages the list holds.
    let mode: Mode

    @State private var kindFilter: KindFilter = .all
    @State private var searchText = ""
    /// Hide everything that was pulled in as a dependency — the official
    /// GUIs' toggle, and the difference between a 70-package list and the
    /// handful the user actually chose.
    @State private var hideDependencies = false

    enum Mode {
        case installed
        case upgrade
    }

    enum KindFilter: String, CaseIterable, Identifiable {
        case all
        case formula
        case cask

        var id: String { rawValue }
    }

    var body: some View {
        let model = vm.homebrew
        let packages = filteredPackages(model)

        HStack(spacing: 0) {
            listColumn(model, packages: packages)
                .frame(width: 304)

            Divider()

            if let selected = model.selectedPackage(from: packages) {
                HomebrewDetailPane(package: selected)
            } else {
                noSelection
            }
        }
        // Both columns claim the full height: the list scrolls inside its
        // column and the detail pane scrolls in the rest, instead of the
        // whole master–detail collapsing to a strip above empty space.
        .frame(maxHeight: .infinity)
    }

    // MARK: - List column

    private func listColumn(_ model: HomebrewModel, packages: [HomebrewPackage]) -> some View {
        VStack(spacing: 0) {
            if mode == .upgrade {
                upgradeAllBlock(model)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }

            filterBar
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if model.snapshot == nil && model.isLoading {
                // The first load is a handful of brew reads; an empty list
                // with no explanation reads as "nothing installed".
                loadingList
            } else if packages.isEmpty {
                emptyList(mode == .upgrade
                    ? L10n.tr("homebrew.outdated.allLatest")
                    : L10n.tr("homebrew.packages.empty"))
            } else {
                // Lazy: a developer's formula list runs into the hundreds.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(packages) { package in
                            packageRow(package, isSelected: model.selectedPackageID == package.id) {
                                model.selectPackage(package)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    /// "Upgrade everything" block: the command the button runs, plus the
    /// button itself with the outdated count.
    private func upgradeAllBlock(_ model: HomebrewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TerminalCommandRow(command: "brew upgrade")

            HStack(spacing: 8) {
                BrandCTAButton(
                    title: L10n.tr("homebrew.detail.upgradeAllAction"),
                    systemImage: "arrow.up.circle",
                    style: .primary,
                    compact: true
                ) {
                    model.run(.upgradeAll)
                }
                .disabled(model.runningAction != nil)
                .help(L10n.tr("homebrew.detail.upgradeAllHelp"))

                Spacer(minLength: 0)
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            Picker(selection: $kindFilter) {
                ForEach(KindFilter.allCases) { filter in
                    Text(verbatim: L10n.tr("homebrew.filter.\(filter.rawValue)")).tag(filter)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Toggle(isOn: $hideDependencies) {
                    Text(verbatim: L10n.tr("homebrew.filter.hideDependencies"))
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                // Only brew's JSON carries the on-request flag; in degraded
                // mode the filter cannot tell, so it stays off rather than
                // emptying the list.
                .disabled(vm.homebrew.snapshot?.detailsAvailable != true)

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(text: $searchText) {
                    Text(verbatim: L10n.tr("homebrew.searchPlaceholder"))
                        .font(.system(size: 12))
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
    }

    private func packageRow(
        _ package: HomebrewPackage,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: package.kind == .formula ? "cube" : "macwindow")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(verbatim: package.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        kindTag(package.kind)

                        if package.isOutdated {
                            outdatedBadge
                        }

                        if package.pinned {
                            pinnedBadge
                        }
                    }

                    if let description = package.description {
                        Text(verbatim: description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: versionLine(package))
                        .font(.system(size: 10))
                        .foregroundStyle(package.isOutdated ? .orange : .secondary)
                        .monospacedDigit()

                    if let size = package.size, size > 0 {
                        Text(verbatim: Formatters.bytes(size))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    /// "1.2.0 → 1.2.1" for outdated packages, the plain version otherwise.
    private func versionLine(_ package: HomebrewPackage) -> String {
        guard package.isOutdated, let latest = package.latestVersion else { return package.installedVersion }
        return L10n.fmt("homebrew.package.upgrade", package.installedVersion, latest)
    }

    private var outdatedBadge: some View {
        Text(verbatim: L10n.tr("homebrew.package.outdated"))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.orange.opacity(0.15))
            )
    }

    private var pinnedBadge: some View {
        Text(verbatim: L10n.tr("homebrew.package.pinned"))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }

    private func kindTag(_ kind: HomebrewPackage.Kind) -> some View {
        Text(verbatim: kind.tagTitle)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(kind == .formula ? .orange : .blue)
    }

    private var loadingList: some View {
        VStack(spacing: 8) {
            Spacer()
            LoadingRow(label: L10n.tr("homebrew.loading"))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyList(_ message: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Text(verbatim: message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSelection: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(verbatim: L10n.tr("homebrew.detail.noSelection"))
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: L10n.tr("homebrew.detail.noSelectionHelp"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Filtering

    private func filteredPackages(_ model: HomebrewModel) -> [HomebrewPackage] {
        let packages = model.packages(for: mode == .upgrade ? .upgrade : .installed)
        let byKind: [HomebrewPackage]
        switch kindFilter {
        case .all: byKind = packages
        case .formula: byKind = packages.filter { $0.kind == .formula }
        case .cask: byKind = packages.filter { $0.kind == .cask }
        }
        // A nil on-request flag (details unavailable) counts as "keep", so
        // degraded mode never empties the list.
        let withoutDependencies = hideDependencies
            ? byKind.filter { $0.installedOnRequest != false }
            : byKind
        return model.filtered(withoutDependencies, by: searchText)
    }
}
