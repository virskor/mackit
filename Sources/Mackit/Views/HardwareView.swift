import SwiftUI

/// Hardware details page: what this machine is.
///
/// Entered from the bottom of the sidebar, embedded in the main window's detail
/// area (the same container as the settings page). The layout follows System
/// Information's single-screen overview: one row of model name + system version
/// at the top, then one row per hardware category below, with several
/// "label value" pairs inside a row, separated by hairlines between rows.
///
/// Data comes from `HardwareSampler.profile()`, sampled once on page entry —
/// this is all static information that stops changing once installed, no need
/// to follow the polling.
struct HardwareView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        let profile = vm.hardwareProfile

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(profile)
                    .padding(.bottom, 18)

                row(symbol: "internaldrive", label: L10n.tr("hw.disk")) {
                    pair(L10n.tr("hw.disk.label"), value(profile.diskName))
                    pair(L10n.tr("hw.disk.available"), Formatters.capacity(profile.diskAvailable))
                    pair(L10n.tr("hw.disk.total"), Formatters.capacity(profile.diskTotal))
                } trailing: {
                    // Opens the disk analysis tool: a treemap and
                    // drill-down navigation dedicated to answering where the
                    // space went — a clearer next step than a single total.
                    Button {
                        vm.analyzeDiskSpace()
                    } label: {
                        Label(L10n.tr("hw.disk.analyze"), systemImage: "chart.pie")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }

                row(symbol: "cpu", label: L10n.tr("hw.cpu")) {
                    pair(L10n.tr("hw.cpu.name"), value(profile.cpuName))
                    pair(L10n.tr("hw.cpu.coresLabel"), value(profile.cpuCores))
                }

                row(symbol: "display", label: L10n.tr("hw.gpu")) {
                    pair(L10n.tr("hw.gpu.model"), value(profile.gpuName))
                    pair(L10n.tr("hw.gpu.resolution"), value(profile.displayResolution))
                }

                row(symbol: "memorychip", label: L10n.tr("hw.memory")) {
                    pair(L10n.tr("hw.memory.label"), Formatters.memory(profile.memoryBytes))
                }

                if profile.hasBattery {
                    row(symbol: "battery.100", label: L10n.tr("hw.battery")) {
                        HStack(spacing: 6) {
                            Text(verbatim: L10n.tr("hw.battery.level"))
                                .foregroundStyle(.secondary)
                            Image(systemName: batterySymbol)
                                .foregroundStyle(batteryTint)
                            Text(verbatim: Formatters.percent(profile.batteryLevel))
                                .monospacedDigit()
                        }
                        pair(L10n.tr("hw.battery.cycles"), String(profile.batteryCycles))
                        pair(
                            L10n.tr("hw.battery.health"),
                            L10n.fmt(
                                "hw.battery.healthValue",
                                profile.batteryHealthStatus.title,
                                Int((profile.batteryHealth * 100).rounded())
                            ),
                            tint: healthTint(profile.batteryHealthStatus)
                        )
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Header

    /// Model name + system version: the title large and bold, the version
    /// number small and secondary, baseline-aligned on the same line.
    private func header(_ profile: HardwareProfile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: value(profile.modelName))
                .font(.system(size: 21, weight: .semibold))

            if !profile.osVersion.isEmpty {
                Text(verbatim: L10n.fmt("hw.osVersion", profile.osVersion, profile.osBuild))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Rows

    /// One row of hardware info: icon + category name, several "label value"
    /// pairs in the middle, plus an action on the far right when needed.
    private func row<Trailing: View>(
        symbol: String,
        label: String,
        @ViewBuilder pairs: () -> some View,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                Text(verbatim: label)
                    .font(.system(size: 12))
                    .frame(width: 62, alignment: .leading)

                // The pairs fill the remaining width: when the row narrows,
                // this text is squeezed first, while the far-right action
                // button stays intact.
                HStack(spacing: 22) { pairs() }
                    .frame(maxWidth: .infinity, alignment: .leading)

                trailing()
            }
            .padding(.vertical, 15)

            Divider()
        }
    }

    /// Row without an action: pass an empty view for `trailing`.
    private func row(
        symbol: String,
        label: String,
        @ViewBuilder pairs: () -> some View
    ) -> some View {
        row(symbol: symbol, label: label, pairs: pairs) { EmptyView() }
    }

    /// One "label value" pair: label in secondary color, value in primary
    /// (can be tinted separately).
    private func pair(_ label: String, _ text: String, tint: Color = .primary) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: label)
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .foregroundStyle(tint)
        }
        .font(.system(size: 12))
        .lineLimit(1)
    }

    // MARK: - Battery

    /// Battery icon: the bolt one while charging, otherwise switch tiers by
    /// level.
    private var batterySymbol: String {
        let profile = vm.hardwareProfile
        if profile.batteryCharging { return "battery.100.bolt" }
        switch profile.batteryLevel {
        case 0.75...: return "battery.100"
        case 0.5...: return "battery.75"
        case 0.25...: return "battery.50"
        default: return "battery.25"
        }
    }

    /// Battery color: green when charging or above 20%, orange at 10–20%,
    /// red below 10%.
    private var batteryTint: Color {
        let profile = vm.hardwareProfile
        if profile.batteryCharging || profile.batteryLevel > 0.2 { return .green }
        if profile.batteryLevel > 0.1 { return .orange }
        return .red
    }

    /// Health tinting: green when normal, orange when service is recommended.
    /// The tinting belongs to the view layer; putting it here rather than on
    /// `BatteryHealthStatus` means the monitor layer needn't depend on SwiftUI.
    private func healthTint(_ status: BatteryHealthStatus) -> Color {
        status == .normal ? .green : .orange
    }

    /// A failed-to-sample item shows a dash rather than blank or 0.
    private func value(_ text: String) -> String {
        text.isEmpty ? "—" : text
    }
}
