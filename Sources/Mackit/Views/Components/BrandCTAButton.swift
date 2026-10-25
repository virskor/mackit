import SwiftUI

/// The primary action button in Lemon's style: a wide green button with bold
/// white text, a tinted drop shadow, and a press-scale response.
///
/// `.borderedProminent` was not used: it paints the window's accent color
/// (blue), which is exactly the generic look this palette exists to avoid.
/// `.plain` on macOS reports no press highlight either, so the scale response
/// comes from a custom ButtonStyle reading `isPressed` — a long-press gesture
/// would instead fight the button's own action.
///
/// The surface is `GlassSurface`: Liquid Glass tinted with the brand green on
/// macOS 26+, the flat gradient described above below that.
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

    /// When set, a spinner replaces the leading image and the button reads as
    /// busy instead of inviting another press — the disabled state alone looks
    /// like "not now" rather than "working on it".
    var showsProgress = false

    /// When set, that shortcut activates the button. The results page's
    /// "Done" keeps Return as the default action, which the previous
    /// borderedProminent button provided.
    var keyboardShortcut: KeyboardShortcut?

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
                    if showsProgress {
                        ProgressView()
                            .controlSize(.small)
                            // A spinner inside a flexible-width HStack
                            // stretches to fill it; the button keeps its size.
                            .fixedSize()
                    } else if let systemImage {
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

    /// Wraps the button label in its surface: Liquid Glass on macOS 26+, the
    /// flat brand fill below that (see `GlassSurface`).
    ///
    /// The glass path drops the CTA's colored drop shadow — glass carries its
    /// own shading, and a shadow under it reads as a smudge. Disabled buttons
    /// stay on the flat path: a dimmed green glass reads as broken rather
    /// than as "not now", the same reasoning behind the disabled fill swap
    /// above.
    @ViewBuilder
    private func surface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        GlassSurface(
            style: style == .primary ? .tinted(BrandPalette.cta) : .regular,
            interactive: true,
            outline: .rounded(cornerRadius: compact ? 8 : 12),
            usesGlass: isEnabled,
            fallback: .fill(background),
            fallbackShadow: style == .primary && isEnabled
                ? (color: BrandPalette.ctaShadow, radius: compact ? 4 : 8, y: compact ? 2 : 4)
                : nil
        ) {
            content()
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
