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
                notInstalled(model)
            } else {
                // One chrome band: the section picker, the space totals and
                // the last outcome. The divider sits under all of it — the
                // way the main content card puts one under its toolbar row
                // (see ContentView) — so what follows reads as the working
                // area, not as more scaffolding.
                sectionPicker(model)
                statsStrip(model)
                outcomeNotice(model)
                Divider()
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
        .overlay(alignment: .bottomTrailing) {
            // The pill's visibility is the model's, not this view's: it goes
            // up on the turn an action starts and survives the view being
            // rebuilt by a sidebar switch. Deriving it here from change
            // notifications loses any action that finishes between two render
            // passes — the coalesced notification never arrives.
            if model.showsStatusPill, let progress = model.progress {
                HomebrewProgressPill(
                    progress: progress,
                    outcome: model.outcome,
                    onCopyLog: {
                        vm.showToast(.success, L10n.tr("homebrew.progress.copied"))
                    },
                    showsLog: Binding(
                        get: { model.showsActionLog },
                        set: { model.setActionLogVisible($0) }
                    )
                )
                .padding(.trailing, 20)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: model.showsStatusPill)
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
                // While the re-query runs the button swaps its label for a
                // spinner and a "refreshing" title: a disabled button alone
                // reads as "not now" rather than "working on it".
                BrandCTAButton(
                    title: model.isLoading
                        ? L10n.tr("homebrew.action.refreshing")
                        : L10n.tr("homebrew.action.refresh"),
                    systemImage: "arrow.clockwise",
                    style: .secondary,
                    compact: true,
                    showsProgress: model.isLoading
                ) {
                    model.reload()
                }
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
            Text(verbatim: L10n.tr("homebrew.section.install"))
                .tag(HomebrewModel.Section.install)
            Text(verbatim: L10n.tr("homebrew.section.services"))
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
        .padding(.bottom, 10)
    }

    /// The official apps badge the counts on the installed and upgrade rows —
    /// the two sections that are lists of packages. Services and the two
    /// support sections carry no count: a badge that appears only after the
    /// section has been visited once reads as a glitch, and "服务 0" is noise
    /// on a machine that runs no brew services.
    private func pickerLabel(_ key: String, count: Int?) -> String {
        guard let count else { return L10n.tr(key) }
        return L10n.fmt("homebrew.section.badge", L10n.tr(key), count)
    }

    // MARK: - Stats & feedback

    /// The space angle: what this installation costs on disk. Only the two
    /// package sections show it, and it deliberately carries no package
    /// counts — the picker's badges already answer "how many", and a second
    /// copy of the same number a line below only invites the question of
    /// which one is current.
    @ViewBuilder
    private func statsStrip(_ model: HomebrewModel) -> some View {
        if let snapshot = model.snapshot,
           model.section == .installed || model.section == .upgrade {
            HStack(spacing: 6) {
                // Symmetric spacers center the stats in the normal case; the
                // degraded/unusable notices below push the group right when
                // either one appears, which keeps them out of the stats' way.
                Spacer(minLength: 0)

                ForEach(Array(stats(snapshot).enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        // The dot the scan banner puts between its facts
                        // ("已发现 105 项 · 18.01 GB"): the app's separator
                        // for inline facts, where a vertical rule would read
                        // as a table.
                        Text(verbatim: L10n.tr("homebrew.stat.separator"))
                            .foregroundStyle(.tertiary)
                    }
                    stat(item.label, item.value)
                }

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
            .padding(.bottom, 12)
        }
    }

    private func stats(_ snapshot: HomebrewSnapshot) -> [(label: String, value: String)] {
        [
            (L10n.tr("homebrew.stat.formulae"), String(snapshot.formulae.count)),
            (L10n.tr("homebrew.stat.casks"), String(snapshot.casks.count)),
            (L10n.tr("homebrew.stat.cache"), Formatters.bytes(snapshot.cacheSize)),
            (L10n.tr("homebrew.stat.cellar"), Formatters.bytes(snapshot.cellarSize)),
        ]
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
            Text(verbatim: value)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        stat(label, String(value))
    }

    /// The last outcome, one row above the section content so an action's
    /// result is visible whichever section is open. The in-flight state is
    /// deliberately not repeated here: the corner pill already carries it
    /// with the progress bar, the step count and the elapsed clock.
    @ViewBuilder
    private func outcomeNotice(_ model: HomebrewModel) -> some View {
        if let outcome = model.outcome {
            NoticeRow(
                systemImage: outcome.succeeded ? "checkmark.circle" : "exclamationmark.triangle",
                tint: outcome.succeeded ? .green : .red,
                message: outcome.message
            )
            .padding(.horizontal, 28)
            .padding(.bottom, 10)
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
        case .install:
            HomebrewInstallPane()
        case .services:
            HomebrewServicesPane()
        case .diagnostics:
            HomebrewEnvironmentPane(mode: .diagnostics)
        case .config:
            HomebrewEnvironmentPane(mode: .config)
        }
    }

    // MARK: - Not installed

    /// The official installer from brew.sh, shown for copying rather than run
    /// in-app: it wants an interactive RETURN confirmation and possibly a
    /// sudo password, which the app's non-interactive runner cannot answer.
    private static let brewInstallCommand =
        "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    private func notInstalled(_ model: HomebrewModel) -> some View {
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

            VStack(spacing: 8) {
                Text(verbatim: L10n.tr("homebrew.notInstalled.commandCaption"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TerminalCommandRow(command: Self.brewInstallCommand)
                    .frame(width: 480)
            }
            .padding(.top, 8)

            // The recheck is the page's main action: `activate()` skips a
            // not-installed page on re-entry, so this button — the same
            // reload the header refresh runs — is what flips the page into
            // the manager once Terminal is done.
            BrandCTAButton(
                title: L10n.tr("homebrew.notInstalled.refresh"),
                systemImage: "arrow.clockwise",
                style: .primary,
                compact: true,
                showsProgress: model.isLoading
            ) {
                model.reload()
            }
            .disabled(model.isLoading || model.runningAction != nil)
            .help(L10n.tr("homebrew.notInstalled.refresh.help"))
            .padding(.top, 4)

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
