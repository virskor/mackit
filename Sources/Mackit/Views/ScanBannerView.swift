import SwiftUI

/// The progress bar hung at the top of the list while scanning is in progress
/// and results already exist.
///
/// Once the scan finds entries, it no longer shows the full-screen progress
/// page, but fills results into the list as it scans; this banner answers
/// "where is it now, how much has been found", so a long scan (a full round on
/// this machine takes over a minute) looks like it's always progressing
/// rather than stuck.
struct ScanBannerView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(L10n.tr(vm.cleanupScope.scanProgressTitleKey))
                            .font(.system(size: 12, weight: .semibold))

                        // The restriction is stated here rather than left to be
                        // discovered: a scroll that silently does nothing reads
                        // as a hang, which is worse than the sliding it prevents.
                        // The chip lives and dies with the banner, so the scan
                        // landing is its own "unfrozen" signal.
                        pausedChip
                    }

                    Text(verbatim: vm.progressLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Text(verbatim: L10n.fmt(
                    L10n.plural("scan.banner.found", vm.items.count),
                    vm.items.count, Formatters.bytes(vm.totalSize)
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
            }

            ProgressView(value: vm.progressFraction)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// "滚动与栏宽已暂停": what the scan freezes besides the entries streaming
    /// in — scrolling the list and dragging the rail's boundary. Neutral rather
    /// than a warning tint: this is a state, not a problem, and the entries
    /// themselves keep arriving.
    ///
    /// Capsule treatment follows RiskBadge, the app's other small state tag.
    private var pausedChip: some View {
        Text(verbatim: L10n.tr("scan.banner.paused"))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}
