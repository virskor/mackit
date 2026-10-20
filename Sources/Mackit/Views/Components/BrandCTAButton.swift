import SwiftUI

/// The primary action button in Lemon's style: a wide green button with bold
/// white text, a tinted drop shadow, and a press-scale response.
///
/// `.borderedProminent` was not used: it paints the window's accent color
/// (blue), which is exactly the generic look this palette exists to avoid.
/// `.plain` on macOS reports no press highlight either, so the scale response
/// comes from a custom ButtonStyle reading `isPressed` — a long-press gesture
/// would instead fight the button's own action.
struct BrandCTAButton: View {
    /// Visual weight. `.primary` carries the brand green; `.secondary` is the
    /// neutral companion for actions that sit next to a primary one (the
    /// general module's "Scan Again" beside "Clean"). Both variants share
    /// their metrics deliberately: a system small-control button placed beside
    /// this one is visibly shorter, which reads as a mistake rather than as a
    /// hierarchy.
    enum Style {
        case primary
        case secondary
    }

    let title: String
    var systemImage: String?

    var style: Style = .primary

    /// Shrinks padding and type for use inside a page header, where the
    /// full-size button would overwhelm the row.
    var compact = false

    /// When set, that shortcut activates the button. The results page's
    /// "Done" keeps Return as the default action, which the previous
    /// borderedProminent button provided.
    var keyboardShortcut: KeyboardShortcut?

    /// Opts into the macOS 26 Liquid Glass surface instead of the flat brand
    /// fill. Gated by availability at the use site: the package still
    /// deploys to macOS 14, where `glassEffect` does not exist and the flat
    /// fill is the only option — hence an opt-in rather than an unconditional
    /// switch.
    var glass = false

    var action: () -> Void

    /// Disabled state swaps the fill and text for muted values instead of
    /// dimming the whole button: a global opacity drop turns the green into a
    /// washed-out mint on the light background, which reads as broken rather
    /// than as "not now".
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            surface {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage)
                    }
                    // The header variant's title embeds a size ("Clean 1.2 GB");
                    // monospaced digits keep it from reflowing as the number changes.
                    Text(verbatim: title)
                        .monospacedDigit()
                }
                .font(.system(size: compact ? 12 : 15, weight: .semibold))
                .frame(minWidth: compact ? 0 : 208)
                .padding(.horizontal, compact ? 14 : 22)
                .padding(.vertical, compact ? 7 : 11)
                .foregroundStyle(foreground)
            }
        }
        .buttonStyle(CTAPressStyle())
        .keyboardShortcut(keyboardShortcut)
    }

    /// Wraps the button label in its surface: Liquid Glass on macOS 26+ when
    /// `glass` is set, the flat brand fill below that.
    ///
    /// The glass path drops the CTA's colored drop shadow — glass carries its
    /// own shading, and a shadow under it reads as a smudge. Disabled buttons
    /// stay on the flat path even with `glass` set: a dimmed green glass
    /// reads as broken rather than as "not now", the same reasoning behind
    /// the disabled fill swap above.
    @ViewBuilder
    private func surface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous)

        if #available(macOS 26.0, *), glass, isEnabled {
            if style == .primary {
                content()
                    .glassEffect(.regular.tint(BrandPalette.cta).interactive(), in: shape)
            } else {
                content()
                    .glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            content()
                .background(background, in: shape)
                .shadow(
                    color: style == .primary && isEnabled ? BrandPalette.ctaShadow : .clear,
                    radius: compact ? 4 : 8,
                    y: compact ? 2 : 4
                )
        }
    }

    /// The neutral variant borrows the disabled primary's fill, so the pair
    /// reads as one control group on either light or dark backgrounds.
    private var background: AnyShapeStyle {
        if style == .primary, isEnabled {
            return AnyShapeStyle(BrandPalette.ctaGradient)
        }
        return AnyShapeStyle(Color.primary.opacity(0.08))
    }

    private var foreground: Color {
        if style == .primary, isEnabled {
            return .white
        }
        return isEnabled ? .primary : .secondary
    }
}

/// Press response for `BrandCTAButton`.
private struct CTAPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
