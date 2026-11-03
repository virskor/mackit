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
            Theme.Palette.windowBackground.opacity(0.82)
                .ignoresSafeArea()

            GlassSurface(
                outline: .rounded(cornerRadius: Theme.Radius.xl),
                fallback: .material(.regularMaterial),
                fallbackShadow: Theme.Elevation.overlay
            ) {
                VStack(spacing: 20) {
                    ProgressRing(progress: progress, diameter: 76, lineWidth: 7) {
                        Text("\(cleanedCount)")
                            .font(Theme.Typography.statHeroCompact)
                            .monospacedDigit()
                    }

                    VStack(spacing: 5) {
                        Text(L10n.tr("clean.progress.title"))
                            .font(Theme.Typography.calloutEmphasis)
                        Text(verbatim: currentTitle)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 320)
                    }

                    if cleanedCount > 0 {
                        Text(verbatim: L10n.fmt(
                            L10n.plural("clean.progress.cleaned", cleanedCount),
                            cleanedCount
                        ))
                        .font(Theme.Typography.footnoteMedium)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }

                    Button(L10n.tr("common.stop"), action: onStop)
                        .buttonStyle(.link)
                        .font(Theme.Typography.footnote)
                }
                .padding(32)
            }
        }
    }
}
