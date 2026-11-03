import SwiftUI

extension Theme {
    /// The type scale.
    ///
    /// These are **fixed point sizes**, not the dynamic-type text styles: the
    /// app lays out dense tables and a menu-bar panel where a user's text-size
    /// setting has to be able to change the rendering without reflowing every
    /// column, so the scale is pinned and the doc comment on each token states
    /// its exact size and weight.
    ///
    /// The names follow the familiar large-to-small order (`body` down to
    /// `micro`) but carry this app's own sizes — `footnote` here is 11, not
    /// the system's — so a token is read as "the app's 11pt text", never as
    /// "whatever the system's footnote is today".
    ///
    /// Weight rides in the token rather than at the call site: a
    /// `medium`/`Emphasis` suffix is the only way the same size at two
    /// weights stays one decision instead of two.
    enum Typography {
        // MARK: - Display

        /// 44 — the Homebrew "not installed" hero glyph.
        static let brandGlyph = Font.system(size: 44)
        /// 30 bold — the general cleanup total.
        static let heroNumberLarge = Font.system(size: 30, weight: .bold)
        /// 24 bold — the scan progress and the empty-state headline.
        static let heroNumber = Font.system(size: 24, weight: .bold)
        /// 22 semibold, rounded design — the numbers the scan progress and
        /// the treemap lead with.
        static let statHero = Font.system(size: 22, weight: .semibold, design: .rounded)
        /// 21 semibold — the hardware page's model name.
        static let pageTitleLarge = Font.system(size: 21, weight: .semibold)
        /// 20 semibold — a page's or the stats overlay's headline value.
        static let pageTitle = Font.system(size: 20, weight: .semibold)
        /// 19 semibold — the Homebrew detail pane's package name.
        static let detailTitle = Font.system(size: 19, weight: .semibold)
        /// 18 bold — the clean result's headline.
        static let resultHero = Font.system(size: 18, weight: .bold)

        // MARK: - Titles

        /// 17 semibold, rounded design — the menu-bar panel's stat value,
        /// the number that has to stay legible at panel size.
        static let statValue = Font.system(size: 17, weight: .semibold, design: .rounded)
        /// 17 bold — a sheet's or a permission prompt's title.
        static let sheetTitle = Font.system(size: 17, weight: .bold)
        /// 17 semibold — the title of a state that has nothing to show.
        static let emptyStateTitle = Font.system(size: 17, weight: .semibold)
        /// 16 bold, rounded design — the panel's headline total, one step
        /// above `statValue` because it is the number the panel exists for.
        static let statValueStrong = Font.system(size: 16, weight: .bold, design: .rounded)
        /// 16 semibold, rounded design — the count inside the clean progress
        /// ring, where a larger number would not fit the circle.
        static let statHeroCompact = Font.system(size: 16, weight: .semibold, design: .rounded)

        // MARK: - Body and below

        /// 15 — a row's title.
        static let title3 = Font.system(size: 15)
        /// 15 semibold — an emphasized row title.
        static let title3Emphasis = Font.system(size: 15, weight: .semibold)
        /// 14 — a paragraph inside a card.
        static let callout = Font.system(size: 14)
        /// 14 semibold — a card's or a section's lead line.
        static let calloutEmphasis = Font.system(size: 14, weight: .semibold)
        /// 13 — body text.
        static let body = Font.system(size: 13)
        /// 13 medium — a labeled value.
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        /// 13 semibold — an emphasized body line.
        static let bodyEmphasis = Font.system(size: 13, weight: .semibold)
        /// 12 — secondary body: hints, descriptions, table cells.
        static let subheadline = Font.system(size: 12)
        /// 12 medium — a secondary label that carries a value.
        static let subheadlineMedium = Font.system(size: 12, weight: .medium)
        /// 12 semibold — a section or column header.
        static let subheadlineEmphasis = Font.system(size: 12, weight: .semibold)
        /// 11 — the workhorse: list rows, control labels, legends.
        static let footnote = Font.system(size: 11)
        /// 11 medium — a row's secondary line.
        static let footnoteMedium = Font.system(size: 11, weight: .medium)
        /// 11 semibold — a control or badge label.
        static let footnoteEmphasis = Font.system(size: 11, weight: .semibold)
        /// 10 — a caption under a title.
        static let caption = Font.system(size: 10)
        /// 10 medium — a caption that carries a value.
        static let captionMedium = Font.system(size: 10, weight: .medium)
        /// 10 semibold — an overline or a small badge label.
        static let captionEmphasis = Font.system(size: 10, weight: .semibold)

        // MARK: - Micro

        /// 9 medium — a caption beside an icon or a badge.
        static let microMedium = Font.system(size: 9, weight: .medium)
        /// 9 semibold — a tag's label.
        static let microEmphasis = Font.system(size: 9, weight: .semibold)
        /// 9 bold — the toast's countdown label, the loudest micro text.
        static let microStrong = Font.system(size: 9, weight: .bold)
        /// 8 semibold — the menu-bar pill's label, the smallest text in the
        /// app.
        static let pillLabel = Font.system(size: 8, weight: .semibold)

        // MARK: - Monospaced

        /// 10 monospaced — a version or a short code fragment.
        static let monospacedCaption = Font.system(size: 10, design: .monospaced)
        /// 11 monospaced — a path, a command, a version: anything the user
        /// may need to read character by character.
        static let monospacedFootnote = Font.system(size: 11, design: .monospaced)
        /// 12 monospaced — the widest monospaced line the detail pane shows.
        static let monospacedSubheadline = Font.system(size: 12, design: .monospaced)

        // MARK: - Symbol sizes

        /// 18 — an SF Symbol drawn beside a row's label.
        static let iconMedium = Font.system(size: 18)
        /// 22 — an SF Symbol drawn as a detail pane's lead glyph.
        static let iconLarge = Font.system(size: 22)
    }
}
