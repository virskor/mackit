import SwiftUI

/// Which glass a surface paints on macOS 26+, and the `Glass` it resolves to.
///
/// A standalone type rather than nested inside `GlassSurface` so the mapping
/// is reachable — and unit-testable — without the generic parameter the
/// surface itself needs.
enum GlassStyle {
    /// The standard density — the default for plates that float over
    /// content.
    case regular
    /// Regular glass carrying a tint, how a plate keeps a semantic color
    /// (the toast's green, the CTA's brand green) on 26+, where the
    /// fallback's colored hairline is no longer drawn.
    case tinted(Color)

    /// The `Glass` this style resolves to on macOS 26+.
    @available(macOS 26.0, *)
    func glass(interactive: Bool) -> Glass {
        let glass: Glass
        switch self {
        case .regular:
            glass = .regular
        case .tinted(let color):
            glass = .regular.tint(color)
        }
        return interactive ? glass.interactive() : glass
    }
}

/// A plate that paints itself as Liquid Glass on macOS 26+ and as the
/// material it always was below that.
///
/// The adaptation is one component rather than `#available` + `glassEffect`
/// repeated at every call site: what differs between the toast, the
/// clean-progress card, the treemap's hover label and the brand CTA is only
/// the glass variant, the outline and what sits on top, while the
/// availability gate and the pre-26 appearance are the same everywhere.
///
/// No `GlassEffectContainer` wraps these: a container merges several glass
/// layers that overlap or abut, and every glass surface in this app is a
/// lone floating element. Wrapping whole screens in one "to be safe" would
/// make unrelated plates sample each other's backdrop.
///
/// Glass replaces the fallback's hairline and shadow instead of stacking on
/// them: it carries its own edge highlight and ambient shading, and a shadow
/// under it reads as a smudge.
struct GlassSurface<Content: View>: View {
    /// What the plate is made of below macOS 26.
    enum Fallback {
        /// A system material, handed to the background untype-erased so the
        /// plate renders exactly as it did when the call site painted the
        /// material directly.
        case material(Material)
        /// A flat fill: the brand gradient, a tint, a hover surface.
        case fill(AnyShapeStyle)
    }

    /// The plate's outline. A case rather than a stored `Shape`: an opaque
    /// shape can be neither stored nor returned from a branch, so each case
    /// builds its own modifier in `body`.
    enum Outline {
        case rounded(cornerRadius: CGFloat)
        case capsule
    }

    private let content: Content
    private let style: GlassStyle
    /// Whether the glass reacts to the pointer. On for controls the user
    /// clicks, off for plates that only display.
    private let interactive: Bool
    private let outline: Outline
    /// Whether macOS 26+ paints glass at all. Off keeps the flat plate even
    /// on 26+, for surfaces that must stay flat: a disabled control's dimmed
    /// glass reads as broken rather than as "not now", and a disabled
    /// navigation chevron carries no surface at all.
    private let usesGlass: Bool
    private let fallback: Fallback
    /// Hairline around the fallback plate.
    private let fallbackHairline: (color: Color, width: CGFloat)?
    /// Drop shadow under the fallback plate.
    private let fallbackShadow: (color: Color, radius: CGFloat, y: CGFloat)?

    init(
        style: GlassStyle = .regular,
        interactive: Bool = false,
        outline: Outline = .rounded(cornerRadius: 12),
        usesGlass: Bool = true,
        fallback: Fallback,
        fallbackHairline: (color: Color, width: CGFloat)? = nil,
        fallbackShadow: (color: Color, radius: CGFloat, y: CGFloat)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.style = style
        self.interactive = interactive
        self.outline = outline
        self.usesGlass = usesGlass
        self.fallback = fallback
        self.fallbackHairline = fallbackHairline
        self.fallbackShadow = fallbackShadow
        self.content = content()
    }

    var body: some View {
        outlineView
    }

    @ViewBuilder
    private var outlineView: some View {
        switch outline {
        case .rounded(let cornerRadius):
            plate(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .capsule:
            plate(Capsule())
        }
    }

    /// The plate in `shape`: Liquid Glass on macOS 26+ when this surface
    /// opts in, the fallback it always had below that.
    ///
    /// `shape` is `InsettableShape` because the fallback's hairline is drawn
    /// with `strokeBorder`, which lives on that protocol; both outlines here
    /// (rounded rectangle, capsule) conform to it.
    ///
    /// The availability check sits here rather than at the reference site:
    /// the compiler guards the `glassEffect` call itself, so a property that
    /// merely *references* glass would still be diagnosed.
    @ViewBuilder
    private func plate<S: InsettableShape>(_ shape: S) -> some View {
        if #available(macOS 26.0, *), usesGlass {
            content.glassEffect(style.glass(interactive: interactive), in: shape)
        } else {
            switch fallback {
            case .material(let material):
                decorate(content.background(material, in: shape), in: shape)
            case .fill(let fill):
                decorate(content.background(fill, in: shape), in: shape)
            }
        }
    }

    /// The fallback plate's hairline and shadow, over whatever fill the
    /// surface chose.
    private func decorate<V: View, S: InsettableShape>(_ base: V, in shape: S) -> some View {
        base
            .overlay {
                if let fallbackHairline {
                    shape.strokeBorder(fallbackHairline.color, lineWidth: fallbackHairline.width)
                }
            }
            .shadow(
                color: fallbackShadow?.color ?? .clear,
                radius: fallbackShadow?.radius ?? 0,
                y: fallbackShadow?.y ?? 0
            )
    }
}
