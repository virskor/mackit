import SwiftUI

/// The right-hand detail pane for one package: the facts `brew info` reports
/// (versions, install date, reason, license, tap, dependencies) plus the
/// upgrade and uninstall actions, each shown beside the command it runs.
struct HomebrewDetailPane: View {
    @Environment(AppViewModel.self) private var vm

    let package: HomebrewPackage

    var body: some View {
        let model = vm.homebrew
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(package)

                if model.snapshot?.detailsAvailable == false {
                    NoticeRow(
                        systemImage: "exclamationmark.triangle",
                        tint: .orange,
                        message: L10n.tr("homebrew.detail.degraded")
                    )
                    .padding(.top, 14)
                }

                if let snapshot = model.snapshot, snapshot.detailsAvailable {
                    facts(package)
                    dependenciesBlock(package, model: model)
                    actionBlocks(package, model: model)
                } else {
                    // Degraded mode still offers the actions — names and
                    // versions are enough to address a package.
                    actionBlocks(package, model: model)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Header

    private func header(_ package: HomebrewPackage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: package.kind == .formula ? "cube.box" : "macwindow")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)

                Text(verbatim: package.displayName)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                PackageKindTag(kind: package.kind)

                if package.isOutdated {
                    OutdatedBadge()
                }

                Spacer(minLength: 0)
            }

            if let description = package.description {
                Text(verbatim: description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Facts

    private func facts(_ package: HomebrewPackage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: L10n.tr("homebrew.detail.title"), symbol: nil, trailing: nil)
                .padding(.top, 18)

            fact(L10n.tr("homebrew.detail.installed"), package.installedVersion, monospaced: true)

            fact(
                L10n.tr("homebrew.detail.latest"),
                package.latestVersion ?? L10n.tr("homebrew.detail.latestUnknown"),
                monospaced: true,
                tint: package.isOutdated ? .orange : nil
            )

            if let installedAt = package.installedAt {
                fact(L10n.tr("homebrew.detail.installDate"), Formatters.relative(installedAt))
            }

            if let reason = installReason(package) {
                fact(L10n.tr("homebrew.detail.installReason"), reason)
            }

            if let license = package.license {
                fact(L10n.tr("homebrew.detail.license"), license)
            }

            if let tap = package.tap {
                fact(L10n.tr("homebrew.detail.source"), tap, monospaced: true)
            }

            if let size = package.size, size > 0 {
                fact(
                    L10n.tr("homebrew.detail.size"),
                    Formatters.bytes(size),
                    monospaced: true
                )
            }

            if let homepage = package.homepage, let url = URL(string: homepage) {
                fact(L10n.tr("homebrew.detail.homepage")) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Text(verbatim: homepage)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help(homepage)
                }
            }
        }
    }

    /// "手动安装 · 从预编译包安装" — brew's own two axes: whether the user
    /// asked for it, and whether it came from a bottle.
    private func installReason(_ package: HomebrewPackage) -> String? {
        var parts: [String] = []
        if let onRequest = package.installedOnRequest {
            parts.append(L10n.tr(onRequest
                ? "homebrew.detail.reason.onRequest"
                : "homebrew.detail.reason.dependency"))
        }
        if let fromBottle = package.pouredFromBottle {
            parts.append(L10n.tr(fromBottle
                ? "homebrew.detail.reason.bottle"
                : "homebrew.detail.reason.source"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Dependencies

    private func dependenciesBlock(_ package: HomebrewPackage, model: HomebrewModel) -> some View {
        let dependents = model.dependents(of: package)
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: L10n.tr("homebrew.detail.dependencies"), symbol: nil, trailing: nil)
                .padding(.top, 18)

            if package.dependencies.isEmpty {
                Text(verbatim: L10n.tr("homebrew.detail.noDependencies"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(package.dependencies, id: \.self) { dependency in
                        Text(verbatim: dependency)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.07))
                            )
                    }
                }
                .padding(.top, 8)
            }

            SectionHeader(title: L10n.tr("homebrew.detail.dependents"), symbol: nil, trailing: nil)
                .padding(.top, 18)

            if dependents.isEmpty {
                Text(verbatim: L10n.tr("homebrew.detail.noDependents"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                // Dependents are why an uninstall fails without
                // --ignore-dependencies; the badge says so before the user
                // presses the button and gets brew's error.
                FlowLayout(spacing: 4) {
                    ForEach(dependents) { dependent in
                        HStack(spacing: 4) {
                            Text(verbatim: dependent.displayName)
                                .font(.system(size: 11, design: .monospaced))
                            Text(verbatim: L10n.tr("homebrew.detail.blocksUninstall"))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.orange.opacity(0.12))
                        )
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Actions

    private func actionBlocks(_ package: HomebrewPackage, model: HomebrewModel) -> some View {
        // Read the pending confirmation here, in the body, rather than only
        // inside the alert binding's getter: a property the body never
        // touches directly is not an observed dependency, so requesting the
        // confirmation would not re-render the pane and the dialog would
        // never appear.
        let awaitingUninstallConfirmation = model.pendingUninstall?.id == package.id

        return VStack(alignment: .leading, spacing: 0) {
            if package.isOutdated {
                SectionHeader(title: L10n.tr("homebrew.detail.upgrade"), symbol: nil, trailing: nil)
                    .padding(.top, 20)

                TerminalCommandRow(command: package.upgradeCommand)
                    .padding(.top, 8)

                HStack(spacing: 8) {
                    BrandCTAButton(
                        title: L10n.fmt("homebrew.detail.upgradeAction", package.latestVersion ?? ""),
                        systemImage: "arrow.up.circle",
                        style: .primary,
                        compact: true
                    ) {
                        model.run(.upgrade(package.kind, package.name))
                    }
                    .disabled(model.runningAction != nil)

                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }

            SectionHeader(title: L10n.tr("homebrew.detail.uninstall"), symbol: nil, trailing: nil)
                .padding(.top, 20)

            TerminalCommandRow(command: package.uninstallCommand)
                .padding(.top, 8)

            Text(verbatim: L10n.tr("homebrew.detail.uninstallHelp"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack(spacing: 8) {
                Button(L10n.tr("homebrew.detail.uninstallAction")) {
                    model.requestUninstall(package)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
                .disabled(model.runningAction != nil)

                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
        // The one irreversible action on the page asks in a dialog rather
        // than deleting on the first press. The destructive button leads so
        // it lands on the trailing side as the default action — the same
        // arrangement as the clean confirmation panel.
        .alert(
            Text(verbatim: L10n.fmt("homebrew.detail.uninstallConfirm", package.displayName)),
            isPresented: Binding(
                get: { awaitingUninstallConfirmation },
                set: { if !$0 { model.cancelUninstall() } }
            ),
            actions: {
                Button(L10n.tr("homebrew.detail.uninstallConfirmAction"), role: .destructive) {
                    model.confirmUninstall()
                }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            },
            message: {
                Text(verbatim: L10n.tr("homebrew.detail.uninstallConfirmNote"))
            }
        )
    }

    // MARK: - Fact row

    private func fact(
        _ label: String,
        _ value: String,
        monospaced: Bool = false,
        tint: Color? = nil
    ) -> some View {
        fact(label) {
            Text(verbatim: value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
        }
    }

    private func fact(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)

            value()
                .font(.system(size: 12))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            // Hairline between facts, the same treatment the hardware page's
            // rows use.
            Divider()
        }
    }
}
