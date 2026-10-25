import SwiftUI

/// The install section: search the local index and install what it finds.
///
/// The names come from `brew search --formula` / `--cask` and the rows are
/// enriched from one bulk `brew info --json=v2` per kind (see
/// `HomebrewSearch`). Installing runs `brew install <name>` — brew resolves
/// the kind from the name itself — through the same action path as every
/// other action, so the progress pill, the log and the post-install refresh
/// all come along for free.
struct HomebrewInstallPane: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        let model = vm.homebrew
        VStack(spacing: 0) {
            searchField(model)
                .padding(.horizontal, 28)
                .padding(.top, 16)

            if model.searchFailed {
                failed
            } else if model.isSearching && model.searchResults == nil {
                loading
            } else if model.searchResults == nil {
                prompt
            } else if let results = model.searchResults, results.isEmpty {
                empty
            } else if let results = model.searchResults {
                resultsList(results, model: model)
            }
        }
    }

    // MARK: - Search field

    private func searchField(_ model: HomebrewModel) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(text: Binding(
                get: { model.searchQuery },
                set: { model.updateSearchQuery($0) }
            )) {
                Text(verbatim: L10n.tr("homebrew.install.placeholder"))
                    .font(.system(size: 12))
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12))

            // The spinner replaces the clear button while a search runs: a
            // second search over stale results is the one state where the
            // field must say "working on it" without moving the rows.
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else if !model.searchQuery.isEmpty {
                Button {
                    model.updateSearchQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("homebrew.install.clear"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    // MARK: - States

    private var loading: some View {
        LoadingRow(label: L10n.tr("homebrew.install.searching"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failed: some View {
        NoticeRow(
            systemImage: "exclamationmark.triangle",
            tint: .red,
            message: L10n.tr("homebrew.install.failed")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var prompt: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(verbatim: L10n.tr("homebrew.install.prompt"))
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: L10n.tr("homebrew.install.promptHelp"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(verbatim: L10n.tr("homebrew.install.noResults"))
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: L10n.tr("homebrew.install.noResultsHelp"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private func resultsList(_ results: [HomebrewSearchResult], model: HomebrewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { result in
                    resultRow(result, model: model)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
        }
    }

    private func resultRow(_ result: HomebrewSearchResult, model: HomebrewModel) -> some View {
        let installed = model.isInstalled(result)
        return HStack(spacing: 10) {
            Image(systemName: result.kind == .formula ? "cube" : "macwindow")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: result.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    PackageKindTag(kind: result.kind)

                    if installed {
                        installedBadge
                    }
                }

                // The description is the reason to pick one hit over another;
                // the version stands in when the details call failed.
                if let description = result.description {
                    Text(verbatim: description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let version = result.latestVersion {
                    Text(verbatim: version)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer(minLength: 8)

            if installed {
                Text(verbatim: L10n.tr("homebrew.install.installed"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                BrandCTAButton(
                    title: L10n.tr("homebrew.install.action"),
                    systemImage: "arrow.down.circle",
                    style: .primary,
                    compact: true
                ) {
                    model.run(.install(result.name))
                }
                .disabled(model.runningAction != nil)
                .help(L10n.tr("homebrew.install.actionHelp"))
            }
        }
        .padding(.vertical, 7)
    }

    private var installedBadge: some View {
        Text(verbatim: L10n.tr("homebrew.install.installedBadge"))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.green)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.green.opacity(0.15))
            )
    }
}
