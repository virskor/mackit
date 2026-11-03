import SwiftUI

/// The app's design tokens: the one place a color, a type size, a corner
/// radius or a shadow is defined, which every view then reads from there.
///
/// Why a namespace in code rather than an asset catalog: most of these
/// values are computed (`Color.primary` at a fixed opacity, so it follows
/// light and dark appearance on its own) or are an opacity applied to a tint
/// the caller picks, and neither survives a trip through a static color set.
/// A catalog would also put the brand gradient out of reach.
///
/// The layers, in the order a view reaches for them:
///
/// - `Theme.Palette` — surfaces, semantic tints, labels and chrome;
/// - `Theme.Typography` — the type scale, from the menu-bar pill's 8pt to
///   the Homebrew hero glyph's 44pt;
/// - `Theme.Radius` — the corner-radius scale;
/// - `Theme.Elevation` — the fallback plates' hairlines and shadows;
/// - `Theme.Motion` — the durations a state change takes to read;
/// - `Theme.Brand` — the brand mark's own colors, the one place a literal
///   RGB triple belongs.
///
/// A magic number written straight into a view is a value that cannot follow
/// appearance, cannot be tuned in one place, and cannot be reviewed as part
/// of a system — which is how the same "row hover" ended up as six different
/// opacities before this existed.
enum Theme {}
