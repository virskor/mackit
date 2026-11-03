import SwiftUI

extension Theme {
    /// Every color the interface paints with, in three families and nothing
    /// outside them.
    ///
    /// - **surfaces** — `Color.primary` / `.quaternary` / `.accentColor` at a
    ///   fixed opacity. These follow the system appearance on their own, so a
    ///   hand-mixed literal would be a color that cannot go dark;
    /// - **semantic tints** — the system colors that carry meaning, applied
    ///   at one of the `Tint` strengths;
    /// - **chrome** — the AppKit colors the window, its text and its
    ///   separators actually use.
    ///
    /// A token plus a locally chosen opacity (`windowBackground.opacity(0.82)`
    /// for the modal scrim) is still on the system: the color is shared and
    /// appearance-aware, and only the strength is the call site's own
    /// decision. What is *not* allowed is a literal RGB triple or a bare
    /// `Color.red` — see `Theme.Brand` for the one exception.
    ///
    /// The app sets no global tint override, so `Color.accentColor` is the
    /// user's system accent: `info` and the accent surfaces deliberately
    /// track it rather than pinning the brand green, which lives in
    /// `Theme.Brand` and appears only where the brand itself does.
    enum Palette {
        // MARK: - Adaptive surfaces

        /// A fill that stays visible without competing with content: a
        /// resting row, a usage bar's track, a tile that is not hovered.
        static let surfaceResting = Color.primary.opacity(0.05)
        /// Pointer-over feedback on a row, chip or capsule. The app's default
        /// hover fill, and the one the search field's list plate matches.
        static let surfaceHover = Color.primary.opacity(0.08)
        /// Selected, pressed, or on.
        static let surfaceActive = Color.primary.opacity(0.12)
        /// `.quaternary` at a quiet strength — a card sitting on the window
        /// background. An `AnyShapeStyle` rather than a `Color` because
        /// `.quaternary` is a `HierarchicalShapeStyle` member: it only exists
        /// as an implicit member in a `ShapeStyle` context, so there is no
        /// `Color` to name.
        static let surfaceCard = AnyShapeStyle(.quaternary.opacity(0.25))
        /// `.quaternary` at control strength — the plate under a toolbar
        /// field or a bordered button, so hand-built surfaces match the
        /// system ones.
        static let surfaceControl = AnyShapeStyle(.quaternary.opacity(0.45))
        /// A neutral fill one step quieter than `surfaceHover`: a chip that
        /// is not the point of its row, a bar's track, a "no data" line.
        /// Built on `Color.secondary` rather than `Color.primary` so it
        /// stays behind whatever text sits on it.
        static let surfaceMuted = Color.secondary.opacity(0.15)

        // MARK: - Accent surfaces

        /// Accent at resting strength: a chip that is accented but not
        /// selected.
        static let accentResting = Color.accentColor.opacity(0.12)
        /// The selected row's accent wash.
        static let accentSelected = Color.accentColor.opacity(0.15)
        /// Accent at full strength: the active footer capsule, the tail of
        /// the panel's glow gradient.
        static let accentActive = Color.accentColor.opacity(0.22)
        /// The vanishing end of a glow gradient.
        static let accentFaint = Color.accentColor.opacity(0.02)

        // MARK: - Semantic tints

        /// Succeeded, healthy, safe.
        static let success = Color.green
        /// Needs attention but is not broken.
        static let warning = Color.orange
        /// Failed, destructive, or in progress and cancellable.
        static let danger = Color.red
        /// The destructive button's drop shadow: the danger hue at the
        /// strength `Theme.Brand.ctaShadow` uses, so the pair reads as one
        /// family of controls.
        static let dangerShadow = Color.red.opacity(0.35)
        /// Neutral information — the accent, for badges that carry no
        /// success/warning/danger meaning.
        static let info = Color.accentColor
        /// An action link: the platform's link blue, kept literal rather than
        /// following the accent, because the panel's actions are meant to
        /// read as links whatever accent the user picked.
        static let link = Color.blue

        // MARK: - Labels and chrome

        /// The standard secondary label.
        static let labelSecondary = Color.secondary
        /// A control that exists but cannot be used right now: a checkmark
        /// beside a row that is not selected.
        static let labelDisabled = Color.secondary.opacity(0.45)
        /// The quietest label — a hint under a title, a category caption.
        static let labelTertiary = Color(nsColor: .tertiaryLabelColor)
        /// Text and symbols that sit on a colored fill — an accent segment,
        /// a selected chip — or directly on the wallpaper, as the stats
        /// overlay does.
        static let onColor = Color.white
        /// The overlay's label: white, dropped so it does not compete with
        /// the value above it.
        static let onColorMuted = Color.white.opacity(0.6)
        /// The overlay's divider: a 1pt white line, faint enough to read as a
        /// separator on any wallpaper. Not `separator`, which is drawn for a
        /// window surface and vanishes against a desktop picture.
        static let onColorSeparator = Color.white.opacity(0.3)
        /// The window's own background, as AppKit paints it.
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
        /// A text view's background, one step off the window's.
        static let textBackground = Color(nsColor: .textBackgroundColor)
        /// The system separator, for a divider that is a real divider.
        static let separator = Color(nsColor: .separatorColor)
        /// A hand-drawn hairline between two segments of one control.
        static let hairline = Color.primary.opacity(0.12)
        /// The outline of an interactive surface at rest and under the
        /// pointer.
        static let border = Color.primary.opacity(0.2)
        static let borderHover = Color.primary.opacity(0.3)

        /// The opacities a semantic tint is allowed to be applied at. A tint
        /// at any other strength is a color nobody can place in the system.
        ///
        /// `Double` rather than `CGFloat` because that is what
        /// `ShapeStyle.opacity` takes — the constants are handed straight to
        /// it, and to `IconBadge`'s `fillOpacity`, without a conversion.
        enum Tint {
            /// A capsule or badge: small enough that a quiet fill still
            /// reads as tinted.
            static let badge: Double = 0.14
            /// A card or panel large enough that the badge strength would
            /// shout.
            static let card: Double = 0.08
            /// A tinted outline, the border that rides with a tinted card.
            static let border: Double = 0.22
            /// The filled part of a progress track.
            static let track: Double = 0.5
        }
    }
}
