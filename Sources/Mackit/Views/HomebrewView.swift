import SwiftUI

/// The Homebrew manager tool page.
///
/// Five sections mirroring the official Homebrew GUIs' information
/// architecture — installed packages, upgrades, services, diagnostics,
/// configuration — with Mackit's own angle kept in view: the cache and
/// Cellar totals, and cleanup actions beside brew's own.
///
/// Embedded in the main window's detail area like the hardware and settings
/// pages (a card, not full-bleed). Entering loads the installed list once
/// and never runs an action on its own — every state-changing step is a
/// button the user presses.
struct HomebrewView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        let model = vm.homebrew
        VStack(spacing: 0) {
            header(model)

            if model.isNotInstalled {
                notInstalled
            } else {
                sectionPicker(model)
                Divider()
                statsStrip(model)
                feedback(model)
                // The section content claims the rest of the card: without
                // this the panes size to their content and the page reads as
                // a thin strip floating above an empty window — lists and
                // detail panes must scroll within the full height, and the
                // loading/empty states center in it.
                sectionContent(model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private func header(_ model: HomebrewModel) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.tr("homebrew.title"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if let snapshot = model.snapshot {
                    Text(verbatim: headerLine(snapshot))
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if model.isLoading {
                    Text(verbatim: L10n.tr("homebrew.loading"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    model.reload()
                } label: {
                    Label(L10n.tr("homebrew.action.refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .disabled(model.isLoading || model.runningAction != nil)
                .help(L10n.tr("homebrew.action.refresh.help"))

                BrandCTAButton(
                    title: L10n.tr("homebrew.action.cleanup"),
                    systemImage: "trash",
                    style: .primary,
                    compact: true
                ) {
                    model.run(.cleanup)
                }
                .disabled(model.runningAction != nil)
                .help(L10n.tr("homebrew.action.cleanup.help"))

                BrandCTAButton(
                    title: L10n.tr("homebrew.action.autoremove"),
                    systemImage: "scissors",
                    style: .secondary,
                    compact: true
                ) {
                    model.run(.autoremove)
                }
                .disabled(model.runningAction != nil)
                .help(L10n.tr("homebrew.action.autoremove.help"))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// "Homebrew 4.4.15 · /opt/homebrew" — the version is the answer to
    /// "is this thing even maintained", the prefix is where everything else
    /// on the page lives.
    private func headerLine(_ snapshot: HomebrewSnapshot) -> String {
        if let version = snapshot.version {
            return L10n.fmt("homebrew.header.version", version, snapshot.prefix)
        }
        return snapshot.prefix
    }

    // MARK: - Section picker

    private func sectionPicker(_ model: HomebrewModel) -> some View {
        Picker(selection: Binding(
            get: { model.section },
            set: { model.showSection($0) }
        )) {
            Text(verbatim: pickerLabel("homebrew.section.installed", count: model.snapshot?.allPackages.count))
                .tag(HomebrewModel.Section.installed)
            Text(verbatim: pickerLabel("homebrew.section.upgrade", count: model.snapshot?.outdated.count))
                .tag(HomebrewModel.Section.upgrade)
            Text(verbatim: pickerLabel("homebrew.section.services", count: model.services?.count))
                .tag(HomebrewModel.Section.services)
            Text(verbatim: L10n.tr("homebrew.section.diagnostics"))
                .tag(HomebrewModel.Section.diagnostics)
            Text(verbatim: L10n.tr("homebrew.section.config"))
                .tag(HomebrewModel.Section.config)
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    /// The official apps badge the outdated count on the installed and
    /// upgrade rows; the count is omitted until the data exists.
    private func pickerLabel(_ key: String, count: Int?) -> String {
        guard let count else { return L10n.tr(key) }
        return L10n.fmt("homebrew.section.badge", L10n.tr(key), count)
    }

    // MARK: - Stats & feedback

    /// The space angle: what this installation costs on disk and how much of
    /// it is stale. Only the two package sections show it.
    @ViewBuilder
    private func statsStrip(_ model: HomebrewModel) -> some View {
        if let snapshot = model.snapshot,
           model.section == .installed || model.section == .upgrade {
            HStack(spacing: 8) {
                stat(L10n.tr("homebrew.stat.formulae"), snapshot.formulae.count)
                stat(L10n.tr("homebrew.stat.casks"), snapshot.casks.count)
                stat(L10n.tr("homebrew.stat.cache"), Formatters.bytes(snapshot.cacheSize))
                stat(L10n.tr("homebrew.stat.cellar"), Formatters.bytes(snapshot.cellarSize))
                stat(L10n.tr("homebrew.stat.outdated"), snapshot.outdated.count, highlight: !snapshot.outdated.isEmpty)
                if !snapshot.detailsAvailable {
                    Spacer(minLength: 4)
                    Label(L10n.tr("homebrew.detail.degraded"), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(L10n.tr("homebrew.detail.degradedHelp"))
                }
                if !snapshot.isUsable {
                    Spacer(minLength: 4)
                    Label(L10n.tr("homebrew.snapshot.unusable"), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 28)
            .padding(.bottom, 10)
        }
    }

    private func stat(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
            Text(verbatim: value)
                .foregroundStyle(highlight ? .orange : .primary)
                .monospacedDigit()
        }
    }

    private func stat(_ label: String, _ value: Int, highlight: Bool = false) -> some View {
        stat(label, String(value), highlight: highlight)
    }

    /// The in-flight action and the last outcome. One row each, above the
    /// section content, so an action's result is visible whichever section
    /// is open.
    @ViewBuilder
    private func feedback(_ model: HomebrewModel) -> some View {
        if let running = model.runningAction {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: runningLabel(running))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 10)
        }

        if let outcome = model.outcome {
            NoticeRow(
                systemImage: outcome.succeeded ? "checkmark.circle" : "exclamationmark.triangle",
                tint: outcome.succeeded ? .green : .red,
                message: outcomeMessage(outcome)
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 10)
        }
    }

    private func runningLabel(_ action: HomebrewAction) -> String {
        switch action {
        case .cleanup: return L10n.tr("homebrew.running.cleanup")
        case .autoremove: return L10n.tr("homebrew.running.autoremove")
        case .upgradeAll: return L10n.tr("homebrew.running.upgradeAll")
        case .upgrade: return L10n.tr("homebrew.running.upgrade")
        case .uninstall: return L10n.tr("homebrew.running.uninstall")
        case .startService, .stopService, .restartService: return L10n.tr("homebrew.running.service")
        }
    }

    private func outcomeMessage(_ outcome: HomebrewOutcome) -> String {
        guard outcome.succeeded else {
            return L10n.fmt("homebrew.result.failed", outcome.failure ?? "")
        }
        switch outcome.action {
        case .cleanup:
            if let bytes = outcome.measure, bytes > 0 {
                return L10n.fmt("homebrew.result.cleaned", Formatters.bytes(bytes))
            }
            return L10n.tr("homebrew.result.cleanedNone")
        case .autoremove:
            if let count = outcome.measure, count > 0 {
                let key = count == 1
                    ? "homebrew.result.autoremoved.one"
                    : "homebrew.result.autoremoved.other"
                return L10n.fmt(key, count)
            }
            return L10n.tr("homebrew.result.autoremovedNone")
        case .upgradeAll:
            return L10n.tr("homebrew.result.upgradedAll")
        case .upgrade(_, let name):
            return L10n.fmt("homebrew.result.upgraded", name)
        case .uninstall(_, let name):
            return L10n.fmt("homebrew.result.uninstalled", name)
        case .startService(let name):
            return L10n.fmt("homebrew.result.serviceStarted", name)
        case .stopService(let name):
            return L10n.fmt("homebrew.result.serviceStopped", name)
        case .restartService(let name):
            return L10n.fmt("homebrew.result.serviceRestarted", name)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionContent(_ model: HomebrewModel) -> some View {
        switch model.section {
        case .installed:
            HomebrewPackagesPane(mode: .installed)
        case .upgrade:
            HomebrewPackagesPane(mode: .upgrade)
        case .services:
            HomebrewServicesPane()
        case .diagnostics:
            HomebrewEnvironmentPane(mode: .diagnostics)
        case .config:
            HomebrewEnvironmentPane(mode: .config)
        }
    }

    // MARK: - Not installed

    private var notInstalled: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "shippingbox")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text(verbatim: L10n.tr("homebrew.notInstalled.title"))
                .font(.system(size: 17, weight: .semibold))

            Text(verbatim: L10n.tr("homebrew.notInstalled.explain"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button {
                if let url = URL(string: "https://brew.sh") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(L10n.tr("homebrew.notInstalled.action"), systemImage: "globe")
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
