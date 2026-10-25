import SwiftUI

/// The services section: the launchd units brew manages for the current
/// user, with start/stop/restart beside the command each runs.
struct HomebrewServicesPane: View {
    @Environment(AppViewModel.self) private var vm

    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case running
        case stopped

        var id: String { rawValue }
    }

    var body: some View {
        let model = vm.homebrew
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TerminalCommandRow(command: "brew services info --all --json")

                Button {
                    model.refreshServices()
                } label: {
                    Label(L10n.tr("homebrew.action.refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .disabled(model.isLoadingServices)

                Picker(selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(verbatim: L10n.tr("homebrew.services.filter.\(option.rawValue)")).tag(option)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)

            if model.isLoadingServices && model.services == nil {
                loading
            } else if model.servicesFailed {
                NoticeRow(
                    systemImage: "exclamationmark.triangle",
                    tint: .red,
                    message: L10n.tr("homebrew.services.failed")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredServices(model).isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredServices(model)) { service in
                            serviceRow(service, model: model)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                }
            }
        }
    }

    private var loading: some View {
        LoadingRow(label: L10n.tr("homebrew.services.loading"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(verbatim: L10n.tr("homebrew.services.empty"))
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: L10n.tr("homebrew.services.emptyHelp"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func serviceRow(_ service: HomebrewService, model: HomebrewModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: service.isRunning ? "play.circle.fill" : "stop.circle")
                .foregroundStyle(service.isRunning ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: service.name)
                        .font(.system(size: 13, weight: .medium))

                    Text(verbatim: statusText(service))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(statusTint(service))
                }

                HStack(spacing: 6) {
                    if let pid = service.pid, service.isRunning {
                        Text(verbatim: L10n.fmt("homebrew.services.pid", pid))
                            .font(.system(size: 10))
                            .monospacedDigit()
                    }
                    if let user = service.user {
                        Text(verbatim: user)
                            .font(.system(size: 10))
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if service.isRunning {
                serviceButton(L10n.tr("homebrew.services.stop"), symbol: "stop.fill") {
                    model.run(.stopService(service.name))
                }
                serviceButton(L10n.tr("homebrew.services.restart"), symbol: "arrow.clockwise") {
                    model.run(.restartService(service.name))
                }
            } else {
                serviceButton(L10n.tr("homebrew.services.start"), symbol: "play.fill") {
                    model.run(.startService(service.name))
                }
            }
        }
        .disabled(model.runningAction != nil)
        .padding(.vertical, 7)
    }

    private func serviceButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// brew's own status words ("started", "none", "scheduled", "stopped",
    /// "error"), shown through their localized labels.
    private func statusText(_ service: HomebrewService) -> String {
        if service.isRunning { return L10n.tr("homebrew.services.status.running") }
        return L10n.tr("homebrew.services.status.\(service.status)")
    }

    private func statusTint(_ service: HomebrewService) -> Color {
        if service.isRunning { return .green }
        if service.status == "error" { return .red }
        return .secondary
    }

    private func filteredServices(_ model: HomebrewModel) -> [HomebrewService] {
        let services = model.services ?? []
        switch filter {
        case .all: return services
        case .running: return services.filter(\.isRunning)
        case .stopped: return services.filter { !$0.isRunning }
        }
    }
}
