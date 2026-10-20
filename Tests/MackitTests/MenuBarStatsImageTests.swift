import AppKit
import Foundation
import Testing

@testable import Mackit

/// Width stability of the menu bar label image.
///
/// The whole item is a single template image whose width follows its text: a
/// value that changes length on every poll (7% → 47%) widens and narrows the
/// item, which the menu bar renders as the icon jumping sideways. Each group
/// therefore has to reserve the widest width it can ever need.
@MainActor
struct MenuBarStatsImageTests {
    /// A percentage group keeps one width from 7% through 100%.
    @Test func percentGroupWidthIsFixed() {
        let widest = [Formatters.percent(1)]
        let widths = ["7%", "47%", "100%"].map { width(value: $0, alternatives: widest) }

        #expect(Set(widths).count == 1)
    }

    /// Same for the thermal-state words, whose four values differ in width by
    /// roughly a factor of two between Chinese and English.
    @Test func thermalStateGroupWidthIsFixed() {
        let states = ["Normal", "Slight", "Serious", "Critical"]
        let widths = states.map { width(value: $0, alternatives: states) }

        #expect(Set(widths).count == 1)
    }

    /// A group without the reservation does follow its value — what keeps the
    /// percentages stable is the reserved width, not the drawing itself.
    @Test func unreservedGroupWidthFollowsTheValue() {
        #expect(width(value: "7%") != width(value: "100%"))
    }

    /// The item is one image covering the menu bar's full height, so the value
    /// and its short label are vertically centered against the bar rather than
    /// top-aligned.
    @Test func imageFillsTheBarHeight() {
        let image = MenuBarStatsImage.image(
            metrics: [.init(value: "47%", label: "CPU")],
            barHeight: 38
        )

        #expect(image.size.height == 38)
        #expect(image.isTemplate)
    }

    /// Turning the icon off removes exactly the icon plus its gap — the values
    /// keep their full width.
    ///
    /// The width was once collapsed to the icon's box when the icon was off,
    /// which clipped every value to its first glyph or two: "27%" read as "27"
    /// and "CPU" as "C". A "got narrower" assertion does not catch that, hence
    /// the exact difference.
    @Test func iconOffRemovesOnlyTheIcon() {
        let withIcon = imageWidth(showIcon: true, barHeight: 38)
        let withoutIcon = imageWidth(showIcon: false, barHeight: 38)

        // iconSize = min(17, 38 * 0.75) = 17, plus iconGap = 5
        let difference = withIcon - withoutIcon
        #expect(abs(difference - 22) < 0.01, "the difference should be 22 (icon 17 + gap 5), got \(difference)")
        // Wider than the icon's own box: the values are laid out, not clipped to it
        #expect(withoutIcon > 17, "after turning the icon off, width must still be reserved for the value, got \(withoutIcon)")
    }

    /// With the icon off and every value off as well, the icon is drawn anyway:
    /// an empty image would take the app out of the menu bar entirely, leaving
    /// no way back into the panel.
    @Test func iconSurvivesWhenNothingElseIsShown() {
        let empty = MenuBarStatsImage.image(metrics: [], barHeight: 38, showIcon: false)

        #expect(empty.size.width > 0)
    }

    private func width(value: String, alternatives: [String] = []) -> CGFloat {
        imageWidth(showIcon: true, barHeight: 24, value: value, alternatives: alternatives)
    }

    private func imageWidth(
        showIcon: Bool,
        barHeight: CGFloat,
        value: String = "47%",
        alternatives: [String] = []
    ) -> CGFloat {
        let image = MenuBarStatsImage.image(
            metrics: [.init(value: value, label: "CPU", alternativeValues: alternatives)],
            barHeight: barHeight,
            showIcon: showIcon
        )
        return image.size.width
    }
}
