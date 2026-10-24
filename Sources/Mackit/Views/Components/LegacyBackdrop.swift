import SwiftUI

/// A backdrop painted only where the sidebar has no Liquid Glass to preserve.
///
/// The sidebar's glass is translucent — it samples whatever sits behind it. On
/// macOS 26+ the thing behind it is the window's own glass backdrop, and the
/// specular gradient the system's sidebars wear comes out of that sampling: an
/// opaque surface painted behind the glass flattens it into a plain gray with
/// no gradient at all. So on 26+ this backdrop stays clear and the glass
/// samples the window directly.
///
/// Below 26 there is no glass to preserve — the window's backdrop is the plain
/// window background color — so the legacy treatment the app has always
/// painted stays. That branch runs on every launch on the floor OS, which is
/// what keeps the older systems looking exactly as they do today.
struct LegacyBackdrop<Legacy: View>: ViewModifier {
    /// The backdrop painted below macOS 26: the window background color at the
    /// window level, the bar material in the sidebar's footer.
    @ViewBuilder var legacy: () -> Legacy

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.background { legacy() }
        }
    }
}

extension View {
    /// Paints `backdrop` behind this view only below macOS 26, where the
    /// sidebar has no Liquid Glass for an opaque surface to flatten.
    func legacyBackdrop<Backdrop: View>(
        @ViewBuilder _ backdrop: @escaping () -> Backdrop
    ) -> some View {
        modifier(LegacyBackdrop(legacy: backdrop))
    }
}
