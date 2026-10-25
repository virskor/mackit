import SwiftUI

/// The diagnostics and configuration sections: `brew doctor`'s output and
/// `brew config`'s key/value facts, shown as brew prints them.
///
/// Both are deliberately verbatim — the page does not interpret warnings or
/// summarize the config, because a user filing a Homebrew issue needs the
/// original text, and a half-understood warning is worse than a copyable one.
struct HomebrewEnvironmentPane: View {
    @Environment(AppViewModel.self) private var vm

    let mode: Mode

    enum Mode {
        case diagnostics
        case config
    }

    var body: some View {
        let model = vm.homebrew
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if mode == .diagnostics {
                    Button {
                        model.refreshDiagnostics()
                    } label: {
                        Label(L10n.tr("homebrew.diagnostics.rerun"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .disabled(model.isLoadingDiagnostics)
                } else {
                    Button {
                        model.refreshConfig()
                    } label: {
                        Label(L10n.tr("homebrew.action.refresh"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .disabled(model.isLoadingConfig)
                }

                if let copyText {
                    Button {
                        Clipboard.copy(copyText)
                    } label: {
                        Label(L10n.tr(copyLabel), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)

            content(model)
        }
    }

    @ViewBuilder
    private func content(_ model: HomebrewModel) -> some View {
        switch mode {
        case .diagnostics:
            if model.isLoadingDiagnostics && model.diagnostics == nil {
                LoadingRow(label: L10n.tr("homebrew.diagnostics.running"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diagnostics = model.diagnostics, !diagnostics.isEmpty {
                monospaced(diagnostics)
            } else {
                emptyRow(L10n.tr("homebrew.diagnostics.empty"))
            }
        case .config:
            if model.isLoadingConfig && model.config == nil {
                LoadingRow(label: L10n.tr("homebrew.config.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let config = model.config, !config.isEmpty {
                configGrid(config)
            } else {
                emptyRow(L10n.tr("homebrew.config.empty"))
            }
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Text(verbatim: message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func monospaced(_ text: String) -> some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 24)
        }
    }

    /// brew's own grouping: the installation's keys first, then the toolchain
    /// facts. The split follows the key names brew prints, so a future key
    /// lands in one of the two groups without special-casing.
    private func configGrid(_ entries: [HomebrewConfigEntry]) -> some View {
        let homebrewKeys: Set<String> = [
            "HOMEBREW_VERSION", "ORIGIN", "HEAD", "Last commit", "Branch",
            "HOMEBREW_PREFIX", "Homebrew Ruby"
        ]
        let isHomebrewKey: (HomebrewConfigEntry) -> Bool = { entry in
            entry.key.hasPrefix("HOMEBREW_") || homebrewKeys.contains(entry.key)
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                group(L10n.tr("homebrew.config.group.homebrew"), entries.filter(isHomebrewKey))
                group(L10n.tr("homebrew.config.group.system"), entries.filter { !isHomebrewKey($0) })
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private func group(_ title: String, _ entries: [HomebrewConfigEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, symbol: nil, trailing: nil)
                .padding(.top, 14)

            if entries.isEmpty {
                Text(verbatim: L10n.tr("homebrew.config.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: entry.key)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 160, alignment: .leading)

                        Text(verbatim: entry.value)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
    }

    private var copyText: String? {
        let model = vm.homebrew
        switch mode {
        case .diagnostics: return model.diagnostics
        case .config:
            guard let config = model.config, !config.isEmpty else { return nil }
            return config.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
    }

    private var copyLabel: String {
        mode == .diagnostics ? "homebrew.diagnostics.copy" : "homebrew.config.copy"
    }
}
