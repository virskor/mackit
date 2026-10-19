import SwiftUI

/// The progress screen while scanning is in progress.
struct ScanProgressView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                ProgressRing(progress: vm.progressFraction, diameter: 92, lineWidth: 8) {
                    Text(verbatim: Formatters.percent(vm.progressFraction))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .accessibilityElement()
                .accessibilityLabel(L10n.tr("scan.progress.label"))

                VStack(spacing: 6) {
                    Text(L10n.tr("scan.progress.title"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(verbatim: vm.progressLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 380)
                }

                // Once entries are found it switches to the list + top progress
                // bar, where the count is shown, so "N items found" is not put
                // here (it is always 0 when this page appears).
                Button(L10n.tr("scan.progress.cancel")) { vm.cancelScan() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
