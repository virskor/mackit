import SwiftUI

/// Animations for the brand surfaces: the scan ring's sweep, and the staggered
/// entrance of the hero screens.
///
/// The motion budget is deliberately spent on interactions, not ambient loops:
/// Lemon's hero is motionless when idle (verified: two screenshots 2.5s apart
/// differ by zero pixels), and a continuous float loop here costs ~25% CPU —
/// in a hidden-title-bar window every animation frame makes AppKit recompute
/// the window's draggable regions by walking the whole SwiftUI tree (sampled:
/// `_resetDragMarginsIfNeeded` → `NSHostingView._regionForOpaqueDescendants`).
/// One-shot `withAnimation` transactions and the scan-only sweep don't have
/// that problem: they finish, and the display cycle goes quiet.
///
/// All of them honor Reduce Motion.
enum BrandAnimations {}

// MARK: - Spinning

/// Continuous rotation, one turn per `period` seconds. Used by the scan ring's
/// sweep arc; linear (not eased) because the sweep should not pulse. Runs only
/// while a scan is in progress, so its cost is bounded by the scan itself.
struct SpinningModifier: ViewModifier {
    var period: Double = 1.5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turned = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(turned ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                    turned = true
                }
            }
    }
}

// MARK: - Entrance

/// Fade-and-rise entrance; `delay` staggers the hero, the copy and the button
/// so a screen assembles itself top-down instead of popping in all at once.
struct RiseModifier: ViewModifier {
    var delay: Double = 0

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 14)
            .onAppear {
                withAnimation(.easeOut(duration: 0.55).delay(reduceMotion ? 0 : delay)) {
                    appeared = true
                }
            }
    }
}

extension View {
    /// Continuous rotation, one turn per `period` seconds. See `SpinningModifier`.
    func spinning(period: Double = 1.5) -> some View {
        modifier(SpinningModifier(period: period))
    }

    /// Fade-and-rise entrance, staggered by `delay`. See `RiseModifier`.
    func rise(delay: Double = 0) -> some View {
        modifier(RiseModifier(delay: delay))
    }
}
