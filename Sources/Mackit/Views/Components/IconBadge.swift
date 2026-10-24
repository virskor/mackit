import SwiftUI

/// Large icon badge on a tinted circle, used on the confirmation panel, the
/// results page, the About page and the menu bar panel.
struct IconBadge: View {
    let systemImage: String
    /// Brand icon (full-color PNG, see BrandIcon); pass it to use it, and fall back to an SF Symbol when nil.
    var image: NSImage?
    var tint: Color = .accentColor
    var diameter: CGFloat = 56
    var symbolSize: CGFloat = 24
    var symbolWeight: Font.Weight = .semibold
    /// Corner radius; pass nil for a full circle.
    var cornerRadius: CGFloat?
    var fillOpacity: Double = 0.14

    var body: some View {
        BrandMark(
            image: image,
            fallbackSymbol: systemImage,
            // Scaled by symbolSize so the mark's weight lines up with the SF
            // Symbol's font size it stands in for.
            size: symbolSize,
            weight: symbolWeight,
            tint: tint
        )
        .frame(width: diameter, height: diameter)
        .background(tint.opacity(fillOpacity), in: badgeShape)
    }

    /// A corner radius of half the diameter looks identical to a full circle, avoiding a shape branch.
    private var badgeShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius ?? diameter / 2, style: .continuous)
    }
}
