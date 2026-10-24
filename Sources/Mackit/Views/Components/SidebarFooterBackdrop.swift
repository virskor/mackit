import SwiftUI

/// The frosted sheet at the foot of the sidebar.
///
/// The footer hangs off the bottom of the list as a safe-area inset, so rows
/// scroll behind it. A footer with no backdrop of its own shows the bottom row
/// straight through its own figures — the "Settings" row lands on top of the
/// "Startup Disk" block and neither reads. The frost blurs whatever scrolls
/// under it out, leaving the footer's own figures crisp on top.
///
/// A material rather than a fill, and a different material per OS: on macOS 26+
/// the sidebar wears Liquid Glass, which is translucent and samples whatever
/// sits behind it, so an opaque surface flattens the glass into a plain gray
/// and saws the footer off the sidebar as a slab. The ultra-thin material
/// frosts just as hard while staying translucent enough for the sidebar's own
/// glass to keep showing through — the footer reads as the bottom of the one
/// sheet rather than as a second panel. Below 26 there is no glass to keep
/// continuous and the footer wears the bar material it always had.
struct SidebarFooterBackdrop: View {
    var body: some View {
        Rectangle().fill(material)
    }

    /// The frost the footer wears: ultra-thin on macOS 26+ so the sidebar's
    /// glass survives it, bar below that where there is no glass to preserve.
    /// The gate is a runtime OS-version check — the branch below 26 runs on
    /// every launch on the floor OS, so macOS 14 and 15 keep the footer exactly
    /// as it was.
    private var material: Material {
        if #available(macOS 26.0, *) {
            return .ultraThinMaterial
        }
        return .bar
    }
}
