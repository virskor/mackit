import AppKit
import Foundation
import Testing

@testable import Mackit

/// Width stability of the menu bar label image, and the value's horizontal
/// placement inside its group.
///
/// The whole item is a single template image whose width follows its text: a
/// value that changes length on every poll (7% → 47%) widens and narrows the
/// item, which the menu bar renders as the icon jumping sideways. Each group
/// therefore has to reserve the widest width it can ever need. The value is
/// drawn centered in its group whatever drove the group's width, so the two
/// lines share one center.
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

    /// The value is centered in its group even when the label is the widest
    /// thing in it — it used to be drawn at the group's left edge, which only
    /// agrees with the centered label while the value itself drives the width.
    @Test func valueIsCenteredWhenTheLabelIsWider() throws {
        // One group, icon off: the image is exactly the group, so the group's
        // center is the image's center.
        let image = MenuBarStatsImage.image(
            metrics: [.init(value: "47%", label: "a much wider label")],
            barHeight: 22,
            showIcon: false
        )

        let (centroid, deviceWidth) = try #require(inkCentroid(of: image))
        // Both lines are drawn centered, so a correct image has its centroid
        // on the center line. Measured against the drawing pipeline: the
        // centered draw lands 0.05px off it, a left-edge-drawn value drags it
        // ~21 device pixels (10.7pt) off. Four pixels of slack covers glyph
        // side bearings; beyond it the two lines no longer share the center.
        #expect(
            abs(centroid - deviceWidth / 2) <= 4,
            "the ink center is \(centroid)px in a \(deviceWidth)px-wide group"
        )
    }

    /// The horizontal centroid of the image's ink, in device pixels, plus the
    /// image's device width. A template image's ink is entirely in the alpha
    /// channel.
    private func inkCentroid(of image: NSImage) -> (x: CGFloat, width: CGFloat)? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data as CFData) else { return nil }

        // Drawn premultiplied-last: four bytes per pixel, alpha last
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel == 4, cgImage.alphaInfo == .premultipliedLast else { return nil }

        var weighted: CGFloat = 0
        var total: CGFloat = 0
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                let alpha = CGFloat(bytes[y * cgImage.bytesPerRow + x * bytesPerPixel + 3])
                if alpha > 0 {
                    weighted += CGFloat(x) * alpha
                    total += alpha
                }
            }
        }
        guard total > 0 else { return nil }
        return (weighted / total, CGFloat(cgImage.width))
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
