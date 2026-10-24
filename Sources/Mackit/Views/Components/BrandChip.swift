import SwiftUI

/// The brand chip: the app's mark and name in a capsule, heading the sidebar
/// footer.
///
/// The capsule hugs its content instead of filling the footer's width — the
/// chip is a tag saying whose storage the block below describes, where a
/// full-width band would read as one more list row. The fill carries the
/// accent tint the badges use (see IconBadge) rather than the sidebar's
/// selection gray, so the chip reads as branding instead of as a row the
/// pointer happens to be over.
struct BrandChip: View {
    var body: some View {
        HStack(spacing: 6) {
            BrandMark(
                image: BrandIcon.image,
                fallbackSymbol: "sparkles",
                size: 15,
                tint: .secondary
            )

            // The name is a proper noun, so it stays a literal rather than
            // going through the localization catalog.
            Text(verbatim: "Mackit")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
}
