import SwiftUI
import Testing

@testable import Mackit

/// The macOS 26 glass mapping behind `GlassSurface`.
///
/// The component itself needs a rendering context; what is verifiable
/// offline is the pure mapping that decides what a plate is made of on
/// macOS 26+ — that a tinted style really resolves to tinted regular glass
/// and that the interactive flag reaches the `Glass` value. The pre-26
/// branch (fill / hairline / shadow) holds no decision of its own: every
/// fallback parameter is the value the call site painted directly before
/// the adaptation, which is what keeps macOS 14 and 15 unchanged.
struct GlassSurfaceTests {
    @Test
    func regularStyleResolvesToRegularGlass() {
        guard #available(macOS 26.0, *) else { return }
        #expect(GlassStyle.regular.glass(interactive: false) == Glass.regular)
    }

    @Test
    func tintedStyleResolvesToTintedRegularGlass() {
        guard #available(macOS 26.0, *) else { return }
        #expect(GlassStyle.tinted(.red).glass(interactive: false) == Glass.regular.tint(.red))
    }

    @Test
    func interactiveFlagReachesTheGlass() {
        guard #available(macOS 26.0, *) else { return }
        #expect(GlassStyle.regular.glass(interactive: true) == Glass.regular.interactive())
        #expect(GlassStyle.regular.glass(interactive: false) == Glass.regular)
    }
}
