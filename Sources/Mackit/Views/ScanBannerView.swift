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
                    Text(L10n.tr("scan.progress.title"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(verbatim: vm.progressLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Text(verbatim: L10n.fmt(
                    vm.items.count == 1 ? "scan.banner.found.one" : "scan.banner.found.other",
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
}
