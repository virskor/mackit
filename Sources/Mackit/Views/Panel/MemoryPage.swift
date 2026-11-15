import AppKit
import SwiftUI

/// The memory tab: pressure, usage composition, swap activity, history and the
/// processes holding the most memory.
///
/// Like every panel page this is dropped inside the coordinator's ScrollView:
/// it fills the available width but never claims a height of its own.
struct MemoryPage: View {
    let snapshot: MenuBarSnapshot
    let cpuName: String
    let icon: (ProcessRank) -> NSImage?
    let onMetricChange: (MemoryChartMetric) -> Void

    private var stats: SystemStats { snapshot.stats }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusSection
            monitorRow
            Divider()
            compositionSection
            Divider()
            swapSection
            Divider()
            historySection
            Divider()
            ProcessRankingList(
                ranking: snapshot.processes,
                ranks: snapshot.processes.topMemory,
                icon: icon
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: L10n.tr("panel.tab.memory"))
                .font(Theme.Typography.statValueStrong)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: totalText)
                .font(Theme.Typography.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var totalText: String {
        guard stats.memoryTotal > 0 else { return L10n.tr("panel.noData") }
        let total = Formatters.memory(stats.memoryTotal)
        if cpuName.isEmpty {
            return L10n.fmt("panel.memory.totalOnly", total)
        }
        return L10n.fmt("panel.memory.total", cpuName, total)
    }

    // MARK: - Status

    /// A machine whose memory sample failed has no percentage to judge, so it
    /// reads as unavailable rather than as a calm zero.
    ///
    /// The kernel's pressure level is authoritative — a high used fraction
    /// alone is not pressure, because macOS keeps memory busy with cache — and
    /// the used-fraction thresholds only fill in when that key is absent.
    private var tone: PanelStatusTone {
        guard stats.memoryTotal > 0 else { return .unavailable }
        if stats.memoryPressureIsCritical { return .high }
        if stats.memoryPressureIsWarning { return .elevated }
        if stats.memoryPressureLevel > 0 { return .normal }
        if stats.memoryUsedFraction >= 0.9 { return .high }
        if stats.memoryUsedFraction >= 0.75 { return .elevated }
        return .normal
    }

    private var statusText: String {
        switch tone {
        case .normal: return L10n.tr("panel.memory.status.normal")
        case .elevated: return L10n.tr("panel.memory.status.elevated")
        case .high: return L10n.tr("panel.memory.status.high")
        case .unavailable: return L10n.tr("panel.noData")
        }
    }

    /// The pressure word shown on the right of the status row and in the
    /// monitor column.
    ///
    /// The kernel key is not documented in the SDK and can be absent. The
    /// word is derived from `tone` — which folds in both that key and the
    /// used-fraction thresholds — so the word and the status row can never
    /// contradict each other.
    private var pressureWord: String {
        guard stats.memoryTotal > 0 else { return "—" }
        switch tone {
        case .high: return L10n.tr("panel.memory.pressure.critical")
        case .elevated: return L10n.tr("panel.memory.pressure.warning")
        case .normal, .unavailable: return L10n.tr("panel.memory.pressure.normal")
        }
    }

    private var topConsumerText: String {
        guard let top = snapshot.processes.topMemory.first else {
            return L10n.tr("panel.noData")
        }
        return L10n.fmt(
            "panel.topConsumer",
            top.name,
            Formatters.bytes(top.memoryBytes)
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
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text(verbatim: L10n.tr("panel.memory.pressure"))
                        .foregroundStyle(.secondary)
                    Text(verbatim: pressureWord)
                        .foregroundStyle(tone.color)
                }
                .font(Theme.Typography.caption)
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
                fraction: stats.memoryUsedFraction,
                tint: tone.color,
                value: stats.memoryTotal > 0
                    ? Formatters.percent(stats.memoryUsedFraction)
                    : "—",
                label: L10n.tr("panel.usage")
            )

            VStack(alignment: .leading, spacing: 10) {
                StatColumn(
                    label: L10n.tr("panel.memory.used"),
                    value: usedOfTotalText
                )
                StatColumn(
                    label: L10n.tr("panel.memory.pressure"),
                    value: pressureWord,
                    tint: tone.color
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var usedOfTotalText: String {
        guard stats.memoryTotal > 0 else { return "—" }
        return L10n.fmt(
            "panel.memory.usedOfTotal",
            Formatters.bytes(stats.memoryUsed),
            Formatters.memory(stats.memoryTotal)
        )
    }

    // MARK: - Composition

    private var compositionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: L10n.tr("panel.memory.composition"))
                .font(Theme.Typography.subheadlineEmphasis)
            CompositionBar(segments: compositionSegments, total: stats.memoryTotal)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading)
                ],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(compositionLegend) { segment in
                    legendRow(segment)
                }
            }
        }
    }

    /// The bar carries the four used categories; free memory is the remainder
    /// of the track, so it is not a segment.
    private var compositionSegments: [CompositionSegment] {
        let composition = stats.memoryComposition
        return [
            CompositionSegment(
                id: "app",
                label: L10n.tr("panel.memory.app"),
                value: composition.app,
                color: Theme.Palette.info
            ),
            CompositionSegment(
                id: "wired",
                label: L10n.tr("panel.memory.wired"),
                value: composition.wired,
                color: Theme.Palette.info.opacity(0.5)
            ),
            CompositionSegment(
                id: "compressed",
                label: L10n.tr("panel.memory.compressed"),
                value: composition.compressed,
                color: Theme.Palette.warning
            ),
            CompositionSegment(
                id: "cached",
                label: L10n.tr("panel.memory.cached"),
                value: composition.cached,
                color: Theme.Palette.labelSecondary
            )
        ]
    }

    /// The legend restates every part of the total, free included, because the
    /// bar alone leaves the remainder unattributed.
    private var compositionLegend: [CompositionSegment] {
        compositionSegments + [
            CompositionSegment(
                id: "free",
                label: L10n.tr("panel.memory.free"),
                value: stats.memoryComposition.free,
                color: Theme.Palette.surfaceMuted
            )
        ]
    }

    private func legendRow(_ segment: CompositionSegment) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(segment.color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(verbatim: segment.label)
                .font(Theme.Typography.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Text(verbatim: Formatters.bytes(segment.value))
                .font(Theme.Typography.footnote)
                .monospacedDigit()
                .lineLimit(1)
                // The number is the point of the legend; a long translated
                // label may shrink, but the value must not truncate.
                .layoutPriority(1)
        }
    }

    // MARK: - Swap

    private var swapSection: some View {
        let swap = stats.swap
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                StatColumn(
                    label: L10n.tr("panel.memory.swapIn"),
                    value: byteRateText(stats.pageInsPerSecond)
                )
                StatColumn(
                    label: L10n.tr("panel.memory.swapOut"),
                    value: byteRateText(stats.pageOutsPerSecond)
                )
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: L10n.tr("panel.memory.swap"))
                    .font(Theme.Typography.subheadline)
                Spacer(minLength: 8)
                Text(verbatim: L10n.fmt(
                    "panel.memory.usedOfTotal",
                    Formatters.bytes(swap.used),
                    Formatters.bytes(swap.total)
                ))
                .font(Theme.Typography.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            swapBar(swap)
        }
    }

    private func byteRateText(_ rate: Double?) -> String {
        rate.map { Formatters.byteRate($0) } ?? "—"
    }

    /// A plain 6pt track: the fraction is the only thing it shows, so it does
    /// not need the full `UsageBar` capsule treatment.
    private func swapBar(_ swap: SwapUsage) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Palette.surfaceResting)
                Capsule()
                    .fill(
                        swap.usedFraction >= 0.8
                            ? Theme.Palette.warning
                            : Theme.Palette.info
                    )
                    .frame(
                        width: max(
                            0,
                            proxy.size.width * min(1, max(0, swap.usedFraction))
                        )
                    )
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: L10n.tr("panel.memory.history"))
                .font(Theme.Typography.subheadlineEmphasis)
            metricPicker
            UsageLineChart(values: snapshot.memoryChartSeries, tint: Theme.Palette.info)
                .frame(height: 56)
        }
    }

    private var metricPicker: some View {
        Picker(
            L10n.tr("panel.memory.history"),
            selection: Binding(
                get: { snapshot.memoryChartMetric },
                set: { onMetricChange($0) }
            )
        ) {
            ForEach(MemoryChartMetric.allCases) { metric in
                Text(verbatim: L10n.tr(metric.titleKey)).tag(metric)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
    }
}
