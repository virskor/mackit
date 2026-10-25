import SwiftUI

/// Floating action toast.
///
/// Differences from the former inline banner:
/// - Floats at the bottom of the window without crowding the content layout;
/// - Disappears automatically after a few seconds, or immediately via the close button;
/// - Uses a spring animation for entry and exit.
///
/// The plate itself stays neutral on every style: the semantic color lives in
/// the leading chip and the countdown hairline instead of washing the whole
/// surface. A success toast used to be a solid green slab on macOS 26+, where
/// `Glass.tint` covers the entire plate — and success is the toast this app
/// shows most, so the window's floating furniture read as permanently green.
struct ToastView: View {
    let banner: Banner
    var onDismiss: () -> Void

    @State private var hoverDismiss = false

    var body: some View {
        GlassSurface(
            // The same neutral plate the progress pill wears while an action
            // runs, so the window's floating furniture reads as one family.
            style: .regular,
            outline: .rounded(cornerRadius: 12),
            fallback: .material(.regularMaterial),
            fallbackShadow: (color: .black.opacity(0.16), radius: 14, y: 5)
        ) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    IconBadge(
                        systemImage: banner.style.symbol,
                        tint: banner.style.tint,
                        diameter: 22,
                        symbolSize: 11,
                        cornerRadius: 7
                    )
                    .accessibilityHidden(true)

                    Text(verbatim: banner.message)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    dismissButton
                }
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 12)

                countdown
                    .padding(.horizontal, 12)
            }
            // The overlay proposes the full window width, and the row's
            // Spacer takes all of it — without this cap the plate stretches
            // edge to edge instead of floating as a compact notice. The cap
            // sits on the plate content (not the row alone) so the countdown
            // is bounded by it too.
            .frame(maxWidth: 440)
        }
    }

    // MARK: - Close

    private var dismissButton: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(5)
                .background(
                    Circle().fill(hoverDismiss ? Color.primary.opacity(0.08) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(L10n.tr("common.dismiss"))
        .accessibilityLabel(L10n.tr("common.dismiss"))
        .onHover { hoverDismiss = $0 }
    }

    // MARK: - Countdown

    /// The auto-dismiss budget as a hairline that drains left to right.
    ///
    /// The toast vanishes on its own after `Banner.autoDismissSeconds`, which
    /// without a countdown reads as the toast disappearing mid-sentence while
    /// the user is still reading it. The bar is anchored to `shownAt` rather
    /// than to view appearance: raising the same message twice reuses the
    /// toast's identity, and only the timestamp tells the two apart.
    ///
    /// Inset by the plate's corner radius so the bar stays on the straight
    /// part of the bottom edge — below macOS 26 the fallback plate does not
    /// clip its content the way glass does.
    @ViewBuilder
    private var countdown: some View {
        TimelineView(.periodic(from: banner.shownAt, by: 0.05)) { context in
            GeometryReader { proxy in
                let fraction = ToastCountdown.remainingFraction(
                    elapsed: context.date.timeIntervalSince(banner.shownAt),
                    total: Banner.autoDismissSeconds
                )
                ZStack(alignment: .leading) {
                    Capsule().fill(banner.style.tint.opacity(0.12))
                    Capsule().fill(banner.style.tint.opacity(0.5))
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 2)
            .accessibilityHidden(true)
        }
    }
}

/// The toast's countdown math, split out so it can be tested without a
/// rendering context.
enum ToastCountdown {
    /// Fraction of the dismiss budget left, clamped to 0…1.
    ///
    /// Clamped at both ends: a timeline tick can land after the view model's
    /// timer has already cleared the toast (negative width would crash the
    /// frame), and the first tick can predate the anchor by a hair.
    static func remainingFraction(elapsed: TimeInterval, total: TimeInterval) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - elapsed / total))
    }
}
