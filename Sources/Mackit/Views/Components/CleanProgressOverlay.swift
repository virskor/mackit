import SwiftUI

/// The overlay shown while a clean runs, parameterized so both the cleanup
/// scan's page and the uninstall tool's page can present the same progress
/// without each binding the view model.
///
/// The vm-bound `CleanProgressView` is a thin wrapper over this; the tool page
/// drives it from its own model.
struct CleanProgressOverlay: View {
    /// 0…1 overall progress.
    let progress: Double
    /// The number of successfully cleaned entries. Failed items also went into
    /// the outcomes; counting all of them directly would describe failures as
    /// "cleaned".
    let cleanedCount: Int
    /// The entry currently being cleaned.
    let currentTitle: String
    /// Stops the clean.
    let onStop: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.82)
                .ignoresSafeArea()

            GlassSurface(
                outline: .rounded(cornerRadius: 16),
                fallback: .material(.regularMaterial),
                fallbackShadow: (color: .black.opacity(0.12), radius: 24, y: 8)
            ) {
                VStack(spacing: 20) {
                    ProgressRing(progress: progress, diameter: 76, lineWidth: 7) {
                        Text("\(cleanedCount)")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }

                    VStack(spacing: 5) {
                        Text(L10n.tr("clean.progress.title"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(verbatim: currentTitle)
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

                    Button(L10n.tr("common.stop"), action: onStop)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                .padding(32)
            }
        }
    }
}
