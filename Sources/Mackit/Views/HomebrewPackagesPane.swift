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

    @State private var kindFilter: HomebrewModel.KindFilter = .all
    @State private var searchText = ""
    /// Which packages the list holds by their on-request flag, chosen from
    /// the filter button's dropdown — the official GUIs' "hide
    /// dependencies" toggle, widened into the three-way choice between
    /// everything, only what the user asked for, and only what something
    /// else pulled in.
    @State private var dependencyFilter: HomebrewModel.DependencyFilter = .all

    enum Mode {
        case installed
        case upgrade
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

    /// "Upgrade everything" block: the command the button runs and the button
    /// itself share one row — the command row takes the leftover width (its
    /// text truncates in the middle) and the button keeps its intrinsic size
    /// on the trailing side, so the block costs one row of height above the
    /// list instead of two.
    private func upgradeAllBlock(_ model: HomebrewModel) -> some View {
        HStack(spacing: 8) {
            TerminalCommandRow(command: "brew upgrade")

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
            .fixedSize()
        }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SegmentedBlock(
                    items: HomebrewModel.KindFilter.allCases,
                    title: { L10n.tr("homebrew.filter.\($0.rawValue)") },
                    selection: $kindFilter
                )

                dependencyFilterMenu
            }

            searchField
        }
    }

    /// The dependency filter as an icon-only dropdown beside the kind band.
    /// A second segmented band for a filter the user sets once and leaves
    /// would double the chrome; a menu keeps the one visible band while the
    /// three dependency options stay one click away.
    ///
    /// While a filter is on, the capsule takes the accent fill with a white
    /// glyph — the same treatment the kind band gives its selected segment,
    /// so the row's two "a filter is on" signals read as one language.
    /// Which option is on stays inside the menu (its checkmark and counts);
    /// the narrowed list is the visible consequence.
    ///
    /// The capsule and the glyph are painted by this view, not by the
    /// Menu's label: on macOS 26 a borderless menu reduces its label to
    /// the bare glyph and discards frame, background and foreground styles
    /// (verified in a standalone window harness — none of them drew). The
    /// Menu therefore carries only an invisible label as the hit target
    /// (a real glyph at opacity 0 — see the comment inside), and the
    /// painted glyph rides above the menu so the active state's white
    /// always covers the label's gray template glyph. Both painted layers
    /// ignore hit testing so clicks reach the menu.
    ///
    /// Each item carries the row count choosing it would leave, composed
    /// with the kind band and the search field, so the menu answers "what
    /// would `brew autoremove` take" before anything runs — the same
    /// GUI-as-a-shortcut-over-the-CLI contract as the command rows.
    ///
    /// The items are toggles, not buttons with checkmark labels: the menu
    /// draws the checkmark from the toggle's state, while a `Label`'s
    /// checkmark image never rendered in this menu. A menu-style `Picker`
    /// was the other state-driven option, but it prints the selected value
    /// beside the button, which an icon-only control cannot afford.
    private var dependencyFilterMenu: some View {
        let effective = effectiveDependencyFilter(vm.homebrew)

        return ZStack {
            // The metrics come off the segmented band beside it — its 12pt
            // labels plus 4pt of vertical padding make its ~22pt height —
            // so the two sit flush instead of a hair taller or shorter,
            // and the 6pt continuous corners match the band's.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(effective == .all ? Color.primary.opacity(0.08) : Color.accentColor)
                .allowsHitTesting(false)

            Menu {
                Section {
                    ForEach(HomebrewModel.DependencyFilter.allCases, id: \.self) { option in
                        Toggle(isOn: Binding(
                            get: { effectiveDependencyFilter(vm.homebrew) == option },
                            set: { selected in
                                // Deselecting the checked item is the clearest
                                // "stop filtering" gesture; it falls back to
                                // "all" instead of leaving nothing selected.
                                dependencyFilter = selected ? option : .all
                            }
                        )) {
                            Text(verbatim: dependencyOptionTitle(option, in: vm.homebrew))
                        }
                    }
                } header: {
                    Text(verbatim: L10n.tr("homebrew.dependencyFilter.title"))
                }
            } label: {
                // A real glyph at opacity 0. The borderless menu sizes its
                // hit target from real content — a Color.clear label lets
                // it collapse to ~11pt wide (measured), which is what made
                // the capsule nearly impossible to click. The opacity
                // holds on first render but the label cell re-renders its
                // glyph as an opaque gray template once the state changes,
                // which is why the painted glyph below must sit ABOVE the
                // menu: identical glyph, same center, so the white fully
                // covers the gray one underneath.
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .regular))
                    .opacity(0)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            // Topmost on purpose — see the label comment above. The
            // non-hittable glyph lets clicks fall through to the menu's
            // target underneath. Regular weight: the three decreasing
            // lines read chunky at medium on the solid accent fill — the
            // platform's own filter buttons draw this glyph regular too.
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(effective == .all ? Color.secondary : Color.white)
                .allowsHitTesting(false)
        }
        .frame(width: 28, height: 22)
        // Only brew's JSON carries the on-request flag; in degraded mode
        // the filter cannot tell, so it stays off rather than emptying
        // the list.
        .disabled(vm.homebrew.snapshot?.detailsAvailable != true)
        .accessibilityLabel(L10n.tr("homebrew.dependencyFilter.help"))
        .accessibilityValue(Text(verbatim: effective == .all
            ? ""
            : L10n.tr("homebrew.dependencyFilter.\(effective.rawValue)")))
        .help(L10n.tr("homebrew.dependencyFilter.help"))
    }

    private var searchField: some View {
        SearchField(
            text: $searchText,
            placeholder: L10n.tr("homebrew.searchPlaceholder"),
            showsClearButton: false
        )
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

                        PackageKindTag(kind: package.kind)

                        if package.isOutdated {
                            OutdatedBadge()
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

    /// The model section whose packages this pane lists.
    private var section: HomebrewModel.Section {
        mode == .upgrade ? .upgrade : .installed
    }

    /// The dependency filter actually in force. A choice made while details
    /// were available must not empty the list after a reload degrades the
    /// snapshot — and the list and the menu's chip must read it the same
    /// way, or the chip would advertise a filter the list is not applying.
    private func effectiveDependencyFilter(_ model: HomebrewModel) -> HomebrewModel.DependencyFilter {
        model.snapshot?.detailsAvailable == true ? dependencyFilter : .all
    }

    /// A menu item's label: the option's name beside the row count choosing
    /// it would leave, composed with the kind band and the search field —
    /// the other active filters narrow along with the option instead of
    /// being silently reset by it.
    private func dependencyOptionTitle(
        _ option: HomebrewModel.DependencyFilter,
        in model: HomebrewModel
    ) -> String {
        let count = model.filtered(
            model.packages(for: section),
            kind: kindFilter,
            dependencies: option,
            by: searchText
        ).count
        return L10n.fmt(
            "homebrew.dependencyFilter.count",
            L10n.tr("homebrew.dependencyFilter.\(option.rawValue)"),
            count
        )
    }

    private func filteredPackages(_ model: HomebrewModel) -> [HomebrewPackage] {
        model.filtered(
            model.packages(for: section),
            kind: kindFilter,
            dependencies: effectiveDependencyFilter(model),
            by: searchText
        )
    }
}
