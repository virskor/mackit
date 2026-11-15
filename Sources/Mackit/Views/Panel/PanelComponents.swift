import AppKit
import SwiftUI

// MARK: - Status

/// The four states a monitoring page's status line can report.
///
/// Both the processor and memory pages map their own thresholds onto this
/// scale, so one set of colors serves the dot, the status text and any value
/// tinted with the same state.
enum PanelStatusTone {
    case normal
    case elevated
    case high
    case unavailable

    var color: Color {
        switch self {
        case .normal: return Theme.Palette.success
        case .elevated: return Theme.Palette.warning
        case .high: return Theme.Palette.danger
        case .unavailable: return Theme.Palette.labelSecondary
        }
    }
}

// MARK: - Rings

/// A circular gauge: a track, a tinted progress arc, and the reading in the
/// middle.
///
/// The ring is decorative — the value and label inside already carry the
/// number — so its shapes stay out of the accessibility tree and VoiceOver
/// hears one combined reading instead of two anonymous circles.
struct UsageRing: View {
    let fraction: Double
    let tint: Color
    let value: String
    let label: String
    var diameter: CGFloat = 86
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            rings
                .accessibilityHidden(true)
            VStack(spacing: 1) {
                Text(verbatim: value)
                    .font(Theme.Typography.statHero)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(verbatim: label)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(width: diameter, height: diameter)
    }

    private var rings: some View {
        ZStack {
            Circle()
                .stroke(Theme.Palette.surfaceResting, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clampedUnitFraction(fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Per-core grid

/// Per-logical-core utilization as one small ring per core.
///
/// Eight fixed columns rather than an adaptive wrapping row: eight is the
/// common Apple Silicon configuration, and a fixed count keeps the grid's
/// rhythm the same whatever the machine reports; core counts that are not a
/// multiple of eight simply wrap to a second row.
struct CoreUsageGrid: View {
    let usages: [Double]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
    private let ringDiameter: CGFloat = 22
    private let ringLineWidth: CGFloat = 2.5

    var body: some View {
        if usages.isEmpty {
            Text(verbatim: L10n.tr("panel.noData"))
                .font(Theme.Typography.footnote)
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(usages.indices, id: \.self) { index in
                    cell(index: index, usage: usages[index])
                }
            }
        }
    }

    private func cell(index: Int, usage: Double) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Theme.Palette.surfaceResting, lineWidth: ringLineWidth)
                Circle()
                    .trim(from: 0, to: clampedUnitFraction(usage))
                    .stroke(
                        Theme.Palette.info,
                        style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: ringDiameter, height: ringDiameter)
            Text(verbatim: "\(index + 1)")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        // The rings are a visual index; the label states the same reading for
        // VoiceOver without enumerating the arc geometry.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.fmt("panel.coreA11y", index + 1, Formatters.percent(usage))
        )
    }
}

// MARK: - History charts

/// CPU history as stacked bars: user at the bottom, system stacked above it.
///
/// The domain is a fixed 0...1 — a bar reaching the top means the whole
/// machine is saturated, since the sampled fractions divide by the total tick
/// count across every core — so a bar's height is comparable across refreshes
/// without re-scaling to the window's peak every time.
struct StackedUsageBars: View {
    let user: [Double]
    let system: [Double]

    private enum Segment {
        case user
        case system
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let count = min(user.count, system.count)
            if count < 2 {
                // Same "sampling just started" line as the overview chart: an
                // empty coordinate system looks broken, a flat line reads as
                // waiting for a second point.
                Capsule()
                    .fill(Theme.Palette.surfaceMuted)
                    .frame(width: size.width, height: 1)
                    .position(x: size.width / 2, y: size.height / 2)
            } else {
                ZStack(alignment: .topLeading) {
                    Path { path in
                        addBars(to: &path, size: size, count: count, segment: .user)
                    }
                    .fill(Theme.Palette.info)

                    Path { path in
                        addBars(to: &path, size: size, count: count, segment: .system)
                    }
                    .fill(Theme.Palette.info.opacity(0.4))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Appends one rectangle per sample. Both segments share a single 0...1
    /// domain, so the system part is clipped at the top when a sample sums
    /// past 100%: letting it run past the top would draw more than a core's
    /// worth of load inside a frame that still reads as one core.
    private func addBars(to path: inout Path, size: CGSize, count: Int, segment: Segment) {
        let slot = size.width / CGFloat(count)
        // A 1pt gap separates neighbouring bars. At under 2pt per slot the gap
        // would leave no bar at all, so dense samples are drawn solid.
        let gap: CGFloat = slot > 2 ? 1 : 0
        let barWidth = max(1, slot - gap)
        for index in 0..<count {
            let userHeight = size.height * clampedUnitFraction(user[index])
            let systemHeight = min(
                size.height * clampedUnitFraction(system[index]),
                size.height - userHeight
            )
            let height = segment == .user ? userHeight : systemHeight
            guard height > 0 else { continue }
            let y = size.height - userHeight - (segment == .user ? 0 : systemHeight)
            path.addRect(CGRect(x: CGFloat(index) * slot, y: y, width: barWidth, height: height))
        }
    }
}

/// Line chart with a gradient wash below the curve.
///
/// A port of the overview's `CPUHistoryChart`, parameterized by tint so the
/// same drawing serves the memory history. Fewer than two points draws the
/// same flat "sampling in progress" line rather than an empty plot.
struct UsageLineChart: View {
    let values: [Double]
    var tint: Color = Theme.Palette.info

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if values.count < 2 {
                    Capsule()
                        .fill(Theme.Palette.surfaceMuted)
                        .frame(width: size.width, height: 1)
                } else {
                    Path { path in
                        for (index, value) in values.enumerated() {
                            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                            let y = size.height * (1 - clampedUnitFraction(value))
                            let point = CGPoint(x: x, y: y)
                            if index == 0 {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                    }
                    .stroke(
                        tint,
                        style: StrokeStyle(
                            lineWidth: Theme.Elevation.accentOutlineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for (index, value) in values.enumerated() {
                            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                            let y = size.height * (1 - clampedUnitFraction(value))
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        // The same fade the overview chart uses, but derived
                        // from the caller's tint so a non-accent chart does not
                        // mix two hues in one plot.
                        LinearGradient(
                            colors: [
                                tint.opacity(Theme.Palette.Tint.border),
                                tint.opacity(Theme.Palette.Tint.card)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Stat columns

/// A labelled value: value on top, label below.
///
/// One cell width-anchored so a row of three columns divides the available
/// width evenly instead of hugging each value's length.
struct StatColumn: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: value)
                .font(Theme.Typography.statValue)
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                // A per-process CPU value or a "used / total" pair can outgrow
                // a narrow column in the longer translations; scaling beats
                // truncating a number mid-digit.
                .minimumScaleFactor(0.8)
            Text(verbatim: label)
                .font(Theme.Typography.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Three columns share the space beside the usage ring; a
                // single long word such as "Temperature" can outgrow one of
                // them, and a shrunk label beats a truncated one.
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Memory composition

/// One segment of the memory composition bar.
///
/// `id` is the language-independent identity the legend iterates over; `label`
/// is already localized by the page that builds the list.
struct CompositionSegment: Identifiable {
    let id: String
    let label: String
    let value: Int64
    let color: Color
}

/// A one-line stacked bar: segments share the track in proportion to `total`,
/// with a 2pt gap so adjacent hues stay distinguishable.
///
/// The caller decides which parts belong in the bar; the remainder of `total`
/// shows through as track, which is how free memory reads without a segment
/// of its own.
struct CompositionBar: View {
    let segments: [CompositionSegment]
    let total: Int64

    private let barHeight: CGFloat = 8
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let visible = segments.filter { $0.value > 0 }
            let gapTotal = CGFloat(max(0, visible.count - 1)) * gap
            let available = max(0, proxy.size.width - gapTotal)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                    .fill(Theme.Palette.surfaceResting)
                if total > 0 {
                    HStack(spacing: gap) {
                        ForEach(visible) { segment in
                            Rectangle()
                                .fill(segment.color)
                                .frame(width: segmentWidth(segment, available: available))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
        }
        .frame(height: barHeight)
        .accessibilityHidden(true)
    }

    private func segmentWidth(_ segment: CompositionSegment, available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let width = available * CGFloat(segment.value) / CGFloat(total)
        return max(0, min(available, width))
    }
}

// MARK: - Ranking

/// The "partial data" capsule beside a ranking header.
///
/// Some system processes cannot be read by a user process, so a sample may
/// be incomplete; stating the share it covers keeps the ranking from
/// presenting itself as the whole picture.
struct PartialDataBadge: View {
    let coverage: Double

    var body: some View {
        Text(verbatim: text)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.warning)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.Palette.warning.opacity(Theme.Palette.Tint.badge), in: Capsule())
    }

    private var text: String {
        let coverageText = coverage > 0
            ? L10n.fmt("panel.coverage", Formatters.percent(coverage))
            : L10n.tr("panel.noData")
        return "\(L10n.tr("panel.partialData")) · \(coverageText)"
    }
}

/// A ranked table of the processes using one resource most.
///
/// The page owns the ScrollView: this list renders every row it is handed and
/// deliberately has no scroll region of its own, so the page's scrolling
/// never stops on an inner list. `ranking` supplies the coverage figures for
/// the header; `ranks` is the one list this card shows.
struct ProcessRankingList: View {
    let ranking: ProcessRanking
    let ranks: [ProcessRank]
    let icon: (ProcessRank) -> NSImage?

    private let rowHeight: CGFloat = 30
    private let iconSize: CGFloat = 18
    private let cpuWidth: CGFloat = 44
    private let memoryWidth: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 6)
            columnHeader
                .padding(.bottom, 2)
            if ranks.isEmpty {
                Text(verbatim: L10n.tr("panel.noData"))
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: rowHeight, alignment: .leading)
            } else {
                ForEach(ranks) { rank in
                    row(rank)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: L10n.tr("panel.topProcesses"))
                .font(Theme.Typography.subheadlineEmphasis)
                .lineLimit(1)
            Spacer(minLength: 8)
            // A complete sample has nothing to warn about; only a sample
            // with unreadable processes wears the badge.
            if ranking.isPartial {
                PartialDataBadge(coverage: ranking.coverage)
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(verbatim: L10n.tr("panel.column.process"))
                // Align "Process" with the names, past the row icon and its gap.
                .padding(.leading, iconSize + 8)
            Spacer(minLength: 8)
            Text(verbatim: L10n.tr("panel.column.cpu"))
                .frame(width: cpuWidth, alignment: .trailing)
            Text(verbatim: L10n.tr("panel.column.memory"))
                .frame(width: memoryWidth, alignment: .trailing)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(.secondary)
    }

    private func row(_ rank: ProcessRank) -> some View {
        HStack(spacing: 8) {
            iconView(for: rank)
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: rank.name)
                    .font(Theme.Typography.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if rank.processCount > 1 {
                    Text(verbatim: L10n.fmt("panel.memory.processCount", rank.processCount))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(verbatim: rank.cpuFraction.map { Formatters.percentUnclamped($0) } ?? "—")
                .font(Theme.Typography.footnote)
                .monospacedDigit()
                .frame(width: cpuWidth, alignment: .trailing)

            Text(verbatim: Formatters.bytes(rank.memoryBytes))
                .font(Theme.Typography.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: memoryWidth, alignment: .trailing)
        }
        .frame(minHeight: rowHeight)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func iconView(for rank: ProcessRank) -> some View {
        if let image = icon(rank) {
            Image(nsImage: image)
                .resizable()
        } else {
            // A daemon has no bundle icon; the gear still anchors the row so
            // names keep their shared left edge.
            Image(systemName: "gearshape")
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared helpers

/// Clamps a sampled fraction to 0...1.
///
/// A non-finite sample would otherwise reach the path geometry and produce an
/// unrenderable coordinate; it reads as an empty ring or bar instead, which
/// matches how the rest of the panel treats "no sample yet".
private func clampedUnitFraction(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(1, max(0, value))
}
