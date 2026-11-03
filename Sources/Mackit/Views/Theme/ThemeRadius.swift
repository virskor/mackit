import SwiftUI

extension Theme {
    /// The corner-radius scale.
    ///
    /// Five steps, and every rounded rectangle in the app sits on one of
    /// them: a shape at a radius nobody else uses is a corner that reads as
    /// an accident next to its neighbours. All of them are drawn with
    /// `.continuous`, which is what makes the small end of the scale work —
    /// a 3pt continuous corner is a squircle, not a clipped corner.
    ///
    /// Where a value moved onto the scale it moved by at most two points,
    /// which on a continuous corner is below the threshold anyone can see;
    /// what it bought is that "a card" is now one radius instead of three.
    enum Radius {
        /// 3 — a tiny chip or tag.
        static let xs: CGFloat = 3
        /// 6 — a row, a tag, a pill, a small fill. The default small radius.
        static let sm: CGFloat = 6
        /// 8 — a card.
        static let md: CGFloat = 8
        /// 12 — a plate: a toast, the menu-bar panel, a big card.
        static let lg: CGFloat = 12
        /// 16 — the modal clean-progress overlay, the roomiest corner in the
        /// app.
        static let xl: CGFloat = 16
    }
}
