import AppKit
import SwiftUI

/// The processor tab: current load, per-core utilization, load history and the
/// processes consuming the most CPU.
///
/// Like every panel page this is dropped inside the coordinator's ScrollView:
/// it fills the available width but never claims a height of its own, so the
/// page cannot scroll independently of the panel.
struct ProcessorPage: View {
    let snapshot: MenuBarSnapshot
    let cpuName: String
    let coreSummary: String
    /// The duration text already run through `Formatters.uptime` by the
    /// coordinator; this page supplies the surrounding localized label.
    let uptime: String
    let icon: (ProcessRank) -> NSImage?
    let onRangeChange: (CPUChartRange) -> Void

    private var stats: SystemStats { snapshot.stats }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusSection
            monitorRow
            Divider()
            coreSection
            Divider()
            historySection
            Divider()
            ProcessRankingList(
                ranking: snapshot.processes,
                ranks: snapshot.processes.topCPU,
                icon: icon
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: L10n.tr("panel.tab.processor"))
                .font(Theme.Typography.statValueStrong)
                .lineLimit(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: cpuName.isEmpty ? L10n.tr("panel.noData") : cpuName)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: L10n.fmt("panel.uptime", uptime))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.labelTertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Status

    /// Nil or non-finite usage has no threshold to fall into: it reads as "no
    /// data" rather than being coerced to a calm 0%.
    private var usage: Double? {
        guard let value = stats.cpuUsage, value.isFinite else { return nil }
        return value
    }

    private var tone: PanelStatusTone {
        guard let usage else { return .unavailable }
        if usage < 0.5 { return .normal }
        if usage < 0.8 { return .elevated }
        return .high
    }

    private var statusText: String {
        switch tone {
        case .normal: return L10n.tr("panel.processor.status.normal")
        case .elevated: return L10n.tr("panel.processor.status.elevated")
        case .high: return L10n.tr("panel.processor.status.high")
        case .unavailable: return L10n.tr("panel.noData")
        }
    }

    private var topConsumerText: String {
        // A group whose CPU delta is not measured yet (the first sample after
        // a long idle) must not be described as the top consumer at 0%; there
        // is no reading to quote.
        guard let top = snapshot.processes.topCPU.first,
              let cpu = top.cpuFraction else {
            return L10n.tr("panel.noData")
        }
        return L10n.fmt(
            "panel.topConsumer",
            top.name,
            Formatters.percentUnclamped(cpu)
        )
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tone.color)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(verbatim: statusText)
                    .font(Theme.Typography.subheadlineEmphasis)
                    .foregroundStyle(tone.color)
            }
            Text(verbatim: topConsumerText)
                .font(Theme.Typography.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Monitor row

    private var monitorRow: some View {
        HStack(alignment: .center, spacing: 14) {
            UsageRing(
                fraction: usage ?? 0,
                tint: tone.color,
                value: usage.map { Formatters.percent($0) } ?? "—",
                label: L10n.tr("panel.usage")
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    StatColumn(
                        label: L10n.tr("panel.user"),
                        value: fractionText(stats.cpuUserFraction)
                    )
                    StatColumn(
                        label: L10n.tr("panel.system"),
                        value: fractionText(stats.cpuSystemFraction)
                    )
                    StatColumn(
                        label: L10n.tr("panel.temperature"),
                        value: stats.temperatureText
                    )
                }
                loadAverageRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fractionText(_ fraction: Double?) -> String {
        fraction.map { Formatters.percent($0) } ?? "—"
    }

    private var loadAverageRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: L10n.tr("panel.loadAverage"))
                .font(Theme.Typography.footnote)
                .foregroundStyle(.secondary)
            Text(verbatim: loadAverageText)
                .font(Theme.Typography.footnoteMedium)
                .monospacedDigit()
        }
    }

    private var loadAverageText: String {
        let load = stats.loadAverage
        guard load.available else { return "—" }
        // Locale-aware two-decimal formatting: the separator and digit shapes
        // follow the running language, unlike a printf format.
        return L10n.fmt(
            "panel.loadAverage.values",
            load.one.formatted(.number.precision(.fractionLength(2))),
            load.five.formatted(.number.precision(.fractionLength(2))),
            load.fifteen.formatted(.number.precision(.fractionLength(2)))
        )
    }

    // MARK: - Cores

    private var coreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: L10n.tr("panel.coreUsage"))
                    .font(Theme.Typography.subheadlineEmphasis)
                Spacer(minLength: 8)
                Text(verbatim: coreSummary)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            CoreUsageGrid(usages: stats.cpuCores)
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: L10n.tr("panel.column.cpu"))
                    .font(Theme.Typography.subheadlineEmphasis)
                Spacer(minLength: 8)
                legendDot(color: Theme.Palette.info, label: L10n.tr("panel.user"))
                legendDot(color: Theme.Palette.info.opacity(0.4), label: L10n.tr("panel.system"))
            }
            rangePicker
            StackedUsageBars(
                user: snapshot.cpuUserSeries,
                system: snapshot.cpuSystemSeries
            )
            .frame(height: 60)
            Text(verbatim: peakAverageText ?? L10n.tr("panel.noData"))
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(verbatim: label)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rangePicker: some View {
        Picker(
            L10n.tr("panel.column.cpu"),
            selection: Binding(
                get: { snapshot.cpuChartRange },
                set: { onRangeChange($0) }
            )
        ) {
            ForEach(CPUChartRange.allCases) { range in
                Text(verbatim: L10n.tr(range.titleKey)).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
    }

    /// Peak and mean of the stacked total, over the shorter of the two series
    /// so a half-filled sample cannot pair a user value with a missing system
    /// value.
    private var peakAverageText: String? {
        let count = min(snapshot.cpuUserSeries.count, snapshot.cpuSystemSeries.count)
        guard count > 0 else { return nil }
        var peak = 0.0
        var sum = 0.0
        for index in 0..<count {
            let total = snapshot.cpuUserSeries[index] + snapshot.cpuSystemSeries[index]
            peak = max(peak, total)
            sum += total
        }
        return L10n.fmt(
            "panel.peakAverage",
            Formatters.percent(peak),
            Formatters.percent(sum / Double(count))
        )
    }
}
