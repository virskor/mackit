import SwiftUI

/// The overlay while cleaning is in progress.
struct CleanProgressView: View {
    @Environment(AppViewModel.self) private var vm

    /// The number of successfully cleaned entries. Failed items also went into
    /// cleanOutcomes; counting all of them directly would describe failures as
    /// "cleaned".
    private var cleanedCount: Int {
        vm.cleanOutcomes.filter(\.succeeded).count
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.82)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressRing(progress: vm.cleanProgress, diameter: 76, lineWidth: 7) {
                    Text("\(cleanedCount)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                VStack(spacing: 5) {
                    Text(L10n.tr("clean.progress.title"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(verbatim: vm.cleanCurrentTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 320)
                }

                if cleanedCount > 0 {
                    Text(verbatim: L10n.fmt(
                        cleanedCount == 1
                            ? "clean.progress.cleaned.one"
                            : "clean.progress.cleaned.other",
                        cleanedCount
                    ))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                Button(L10n.tr("common.stop")) { vm.cancelClean() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(32)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        }
    }
}
