import SwiftUI

extension Theme {
    /// The fallback plates' shadows and hairlines.
    ///
    /// Every glass surface below macOS 26 draws a hairline and a shadow by
    /// hand, so the values live here rather than being re-invented at each
    /// call site: a plate that floats one pointer-height above its content
    /// and a plate that floats three should not be decided twice.
    ///
    /// The brand CTA's shadow is deliberately absent — its geometry scales
    /// with the button's own size and its color is the button's, so it stays
    /// with the button.
    enum Elevation {
        /// A plate floating over content: the toast, the progress pill.
        static let plate: (color: Color, radius: CGFloat, y: CGFloat) =
            (color: .black.opacity(0.16), radius: 14, y: 5)
        /// The menu-bar panel, the largest always-on shadow.
        static let panel: (color: Color, radius: CGFloat, y: CGFloat) =
            (color: .black.opacity(0.2), radius: 8, y: 3)
        /// The modal clean-progress overlay, which floats over the whole
        /// window.
        static let overlay: (color: Color, radius: CGFloat, y: CGFloat) =
            (color: .black.opacity(0.12), radius: 24, y: 8)
        /// The treemap's hover label, which hugs its content.
        static let label: (color: Color, radius: CGFloat, y: CGFloat) =
            (color: .black.opacity(0.16), radius: 7, y: 2)
        /// Text sitting directly on the wallpaper, where it washes out on a
        /// light background.
        static let text: (color: Color, radius: CGFloat, y: CGFloat) =
            (color: .black.opacity(0.35), radius: 2, y: 1)

        /// A hairline drawn between two segments of one control.
        static let hairlineWidth: CGFloat = 0.5
        /// A hairline outlining a plate.
        static let outlineWidth: CGFloat = 1
        /// The accent outline of a selected element: heavier than a hairline
        /// because it is the only thing marking the selection on a shape
        /// that carries no fill of its own.
        static let accentOutlineWidth: CGFloat = 1.5
        /// The opacity a semantic tint carries when it is drawn as a
        /// hairline rather than a fill: the progress pill's success/failure
        /// edge.
        static let hairlineStrength: Double = 0.35
    }
}
