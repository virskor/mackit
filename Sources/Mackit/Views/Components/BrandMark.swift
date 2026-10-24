import SwiftUI

/// The brand mark at an arbitrary size, with an SF Symbol standing in when the
/// asset is missing.
///
/// Shared by the large badges (IconBadge) and the sidebar footer's brand chip,
/// so the mark is loaded once and drawn one way. The mark itself is full-color
/// — a rasterized PNG rather than a template image — so `foregroundStyle` has
/// no effect on it, and it takes an explicit frame instead of inheriting the
/// label's font the way an SF Symbol would.
struct BrandMark: View {
    /// The brand asset (see BrandIcon); nil shows `fallbackSymbol`.
    var image: NSImage?
    /// Stands in when the asset is missing. Nil leaves the slot empty.
    var fallbackSymbol: String?
    var size: CGFloat
    var weight: Font.Weight = .regular
    var tint: Color = .accentColor

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else if let fallbackSymbol {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
        }
    }
}
