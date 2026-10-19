import SwiftUI

/// Large icon badge on a tinted background, used on the welcome page, the confirmation
/// panel, the results page, and the About page.
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
        Group {
            if let image {
                // Full-color brand image: does not take tint (not a template image,
                // foregroundStyle has no effect on it); scaled by symbolSize to align
                // its visual weight with the SF Symbol's font size.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: symbolSize, height: symbolSize)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: symbolSize, weight: symbolWeight))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: diameter, height: diameter)
        .background(tint.opacity(fillOpacity), in: badgeShape)
    }

    /// A corner radius of half the diameter looks identical to a full circle, avoiding a shape branch.
    private var badgeShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius ?? diameter / 2, style: .continuous)
    }
}
