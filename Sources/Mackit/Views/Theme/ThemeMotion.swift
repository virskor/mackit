import SwiftUI

extension Theme {
    /// How long a state change takes to read.
    ///
    /// Only the durations that repeat belong here: a value used once is a
    /// decision about that one animation (how long the success mark takes to
    /// draw, how long a row takes to fold), while a value used five times is
    /// a decision the whole interface has already made and should not be
    /// re-litigated per view.
    enum Motion {
        /// The app's state-change feedback — hover, press, selection, a
        /// segment switch. Fast enough that the control feels immediate,
        /// slow enough that the change reads as a transition rather than a
        /// jump.
        static let stateChange: Double = 0.12
    }
}
