import AppKit
import CoreGraphics
import CoreText
import SwiftUI

/// Menu bar stats label: icon + each group's "value / short label" composed into a single template image.
///
/// Why not use a SwiftUI view directly: tested on macOS 27, inside MenuBarExtra's
/// label only the first Text renders—stacking two Texts in a VStack or placing
/// multiple groups side by side in an HStack both leave only the leading one
/// (Shape + .fill does not render at all, see MenuBarIcon's comments). The layout
/// found in other menu bar stats—"value on top, short label below, a thin line
/// between groups"—therefore has to be drawn into the image: the whole thing is
/// handed over as isTemplate, the system tints it according to the menu bar's
/// light/dark appearance, using the same channel as MenuBarIcon.
///
/// Every value is drawn with monospaced digits, and each group reserves the
/// widest width it can ever need — the caller lists a value's possible
/// renderings in `Metric.alternativeValues`. Percentages are clamped to 0–100
/// with no decimals, so their widest rendering is "100%"; temperature is given
/// as a thermal state word (macOS has no public temperature-value API), whose
/// four possible values differ in width by a factor of two. A value whose
/// length changes with each poll (7% → 47%) would otherwise widen and narrow
/// the whole menu bar item, which reads as jitter.
@MainActor
enum MenuBarStatsImage {
    /// One group of "value + short label".
    struct Metric {
        let value: String
        let label: String
        /// What other values this group's value may take. Group width reserves the widest
        /// among them: a group whose value changes width (thermal state words) thus does
        /// not stretch or shrink as the state switches.
        var alternativeValues: [String] = []
    }

    // MARK: - Layout constants (points)

    /// Spacing between the icon and the first group.
    private static let iconGap: CGFloat = 5
    /// Padding on both sides of the separator line between groups.
    private static let separatorPadding: CGFloat = 3
    /// Separator line width and lightness. A template image only takes the alpha channel, so lightness is opacity.
    private static let separatorWidth: CGFloat = 1
    private static let separatorAlpha: CGFloat = 0.35
    /// Alpha of the short label: secondary information is one notch lighter.
    private static let labelAlpha: CGFloat = 0.6
    /// Extra spacing between the value baseline and the short label baseline. Digits
    /// take up no descender space, so a 1pt visual gap reads as tight but not touching.
    private static let lineGap: CGFloat = 1
    /// Rasterization scale. 2x is exactly 1:1 device pixels on Retina—neither blurry nor wasteful.
    private static let scale: CGFloat = 2

    /// Draws a label image. When `metrics` is empty, only the icon remains.
    ///
    /// - Parameter barHeight: Menu bar height. Machines with a notch are about 38pt,
    ///   without about 22pt; the two-line font sizes are tiered accordingly—a
    ///   13 + 8 two-line stack does not fit in a narrow menu bar.
    /// - Parameter showIcon: Whether to draw the brand icon in front of the
    ///   values. Off only takes effect while there is at least one value to
    ///   show: with the icon off and `metrics` empty as well the item would be
    ///   an empty image, and the app would vanish from the menu bar with no way
    ///   back — so in that case the icon is drawn regardless.
    static func image(metrics: [Metric], barHeight: CGFloat, showIcon: Bool = true) -> NSImage {
        let iconSize: CGFloat = min(17, barHeight * 0.75)
        let valueSize: CGFloat = barHeight >= 30 ? 13 : 11
        let labelSize: CGFloat = barHeight >= 30 ? 8 : 7

        // Measure the text first: the line objects give the typographic width and
        // ascent / descent, on which the total width and the vertical placement of
        // the two-line block both depend—they cannot be guessed.
        let measured = metrics.map { measure($0, valueSize: valueSize, labelSize: labelSize) }

        let drawIcon = showIcon || measured.isEmpty

        let blockHeight = measured.map(\.height).max() ?? 0
        // With the icon gone the item is just the text block, so it centers on
        // the bar by itself rather than by the icon's box.
        let contentHeight = drawIcon ? max(iconSize, blockHeight) : blockHeight
        // Content is vertically centered in the menu bar; y is always computed top-down and flipped when drawing.
        let top = (barHeight - contentHeight) / 2

        let separators = CGFloat(max(0, measured.count - 1)) * (separatorWidth + separatorPadding * 2)
        let metricsWidth = measured.reduce(0) { $0 + $1.width } + separators
        // The values' width is their own: dropping the icon must not shrink the
        // image to the icon's box, or every value gets clipped to its first
        // glyph or two ("27%" reads as "27", "CPU" as "C").
        let width: CGFloat
        if measured.isEmpty {
            width = iconSize
        } else if drawIcon {
            width = iconSize + iconGap + metricsWidth
        } else {
            width = metricsWidth
        }

        let pixels = Int((width * scale).rounded())
        let heightPixels = Int((barHeight * scale).rounded())
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixels,
            height: heightPixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), pixels > 0, heightPixels > 0 else {
            return MenuBarIcon.templateImage(pointSize: iconSize)
        }
        // From here on, everything is drawn in the "points, y-up" user space: scaling is
        // left to the CTM, and the bitmap itself is rasterized at 2x.
        context.scaleBy(x: scale, y: scale)

        // Icon: the double-star path is mapped from the SVG's 24×24 design space into the
        // iconSize box. The y-down -> y-up flip is done inside the path transform (d
        // negated), not by flipping the whole context—CoreText text is drawn y-up, so
        // flipping the context would turn the text upside down.
        if drawIcon {
            let iconTop = top + (contentHeight - iconSize) / 2
            let pathScale = iconSize / 24
            var iconTransform = CGAffineTransform(
                a: pathScale, b: 0, c: 0, d: -pathScale, tx: 0, ty: barHeight - iconTop
            )
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            for path in [MenuBarStarPath.back, MenuBarStarPath.front] {
                context.addPath(path.copy(using: &iconTransform) ?? path)
                context.fillPath()
            }
        }

        // Each group's value and short label: short label centered below the value, thin separator line between groups.
        var x = drawIcon ? iconSize + iconGap : 0
        for (index, item) in measured.enumerated() {
            let valueBaseline = top + item.valueAscent
            let labelBaseline = valueBaseline + lineGap + item.labelAscent

            context.textPosition = CGPoint(x: x, y: barHeight - valueBaseline)
            CTLineDraw(item.value, context)

            let labelX = x + (item.width - item.labelWidth) / 2
            context.textPosition = CGPoint(x: labelX, y: barHeight - labelBaseline)
            CTLineDraw(item.label, context)

            if index < measured.count - 1 {
                let lineTop = top + 1
                let lineHeight = blockHeight - 2
                context.setFillColor(CGColor(gray: 0, alpha: separatorAlpha))
                context.fill(CGRect(
                    x: x + item.width + separatorPadding,
                    y: barHeight - lineTop - lineHeight,
                    width: separatorWidth,
                    height: lineHeight
                ))
            }

            x += item.width + separatorWidth + separatorPadding * 2
        }

        guard let cgImage = context.makeImage() else {
            return MenuBarIcon.templateImage(pointSize: iconSize)
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: barHeight))
        image.isTemplate = true
        // A pure image has no readable text; give VoiceOver an equivalent description
        image.accessibilityDescription = metrics
            .map { "\($0.label) \($0.value)" }
            .joined(separator: ", ")
        return image
    }

    // MARK: - Text measurement

    /// One group of measured text.
    private struct Measured {
        let value: CTLine
        let label: CTLine
        /// Group width = max(value width, label width). The short label is centered within the group.
        let width: CGFloat
        let labelWidth: CGFloat
        let valueAscent: CGFloat
        let labelAscent: CGFloat
        /// Height of the two-line block: value line + gap + label line.
        let height: CGFloat
    }

    private static func measure(
        _ metric: Metric, valueSize: CGFloat, labelSize: CGFloat
    ) -> Measured {
        let label = line(metric.label, size: labelSize, weight: .medium, alpha: labelAlpha)
        let labelBounds = typographicBounds(of: label)

        // Group width is computed from the widest of all possible values. Thermal state words
        // differ in width by a factor of two between Chinese and English (Normal ↔
        // Critical); without a fixed width, the menu bar item would jitter wider and
        // narrower whenever the state changes.
        let value = line(metric.value, size: valueSize, weight: .semibold, alpha: 1, monospacedDigits: true)
        var bounds = typographicBounds(of: value)
        for alternative in metric.alternativeValues {
            let candidate = typographicBounds(
                of: line(alternative, size: valueSize, weight: .semibold, alpha: 1, monospacedDigits: true)
            )
            if candidate.width > bounds.width { bounds = candidate }
        }

        return Measured(
            value: value,
            label: label,
            width: max(bounds.width, labelBounds.width),
            labelWidth: labelBounds.width,
            valueAscent: bounds.ascent,
            labelAscent: labelBounds.ascent,
            height: bounds.ascent + lineGap + labelBounds.ascent + labelBounds.descent
        )
    }

    /// One line of text. A template image only takes alpha; lightness is expressed entirely through opacity.
    ///
    /// Values pass `monospacedDigits`: every digit then takes up the same advance
    /// width, so the digits line up on one grid instead of the second digit
    /// sliding sideways with each glyph's own width as the value refreshes.
    private static func line(
        _ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat,
        monospacedDigits: Bool = false
    ) -> CTLine {
        let font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0, alpha: alpha)
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes) as CFAttributedString
        )
    }

    private static func typographicBounds(
        of line: CTLine
    ) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (width, ascent, descent)
    }
}
