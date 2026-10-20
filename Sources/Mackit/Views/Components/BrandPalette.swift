import SwiftUI

/// The warm brand palette, following Tencent Lemon's visual language: amber
/// gradients for the brand mark, a saturated green for the primary action, and
/// everything else left to the system's adaptive colors.
///
/// The default SwiftUI accent (blue) is deliberately not used for the primary
/// action: on this app's surfaces a blue button reads as generic scaffolding,
/// while the amber/green pairing is what makes the interface feel like a
/// product rather than a demo.
enum BrandPalette {
    // MARK: Brand mark

    /// Amber — the light end of the brand gradient.
    static let amber = Color(red: 1.00, green: 0.76, blue: 0.30)
    /// Lemon yellow, slightly deeper than amber.
    static let lemon = Color(red: 1.00, green: 0.68, blue: 0.22)
    /// Deep orange — the dark end of the brand gradient.
    static let deepOrange = Color(red: 1.00, green: 0.55, blue: 0.16)

    // MARK: Primary action

    /// Lemon-style green: the one color allowed to compete with the brand mark.
    static let cta = Color(red: 0.18, green: 0.76, blue: 0.51)
    static let ctaDeep = Color(red: 0.14, green: 0.66, blue: 0.44)
    /// The CTA's fill: a barely-there vertical gradient gives the flat green
    /// some depth without turning it into a glossy button.
    static let ctaGradient = LinearGradient(
        colors: [cta, ctaDeep],
        startPoint: .top,
        endPoint: .bottom
    )
    /// Drop shadow under the CTA: the green's own hue at low opacity, so the
    /// shadow reads as ambient occlusion rather than a gray smudge.
    static let ctaShadow = Color(red: 0.10, green: 0.55, blue: 0.38).opacity(0.35)
}
