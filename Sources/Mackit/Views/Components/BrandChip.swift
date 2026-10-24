import SwiftUI

/// The brand chip: the app's mark and name in a capsule, heading the sidebar
/// footer.
///
/// The capsule hugs its content instead of filling the footer's width — the
/// chip is a tag saying whose storage the block below describes, where a
/// full-width band would read as one more list row.
struct BrandChip: View {
    var body: some View {
        FooterCapsule {
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
            }
        }
    }
}
