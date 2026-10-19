import SwiftUI

/// Floating action toast.
///
/// Differences from the former inline banner:
/// - Floats at the bottom of the window without crowding the content layout;
/// - Disappears automatically after a few seconds, or immediately via the close button;
/// - Uses a spring animation for entry and exit.
struct ToastView: View {
    let banner: Banner
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.style.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(banner.style.tint)

            Text(verbatim: banner.message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("common.dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(banner.style.tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
        .accessibilityAddTraits(.isStaticText)
    }
}
