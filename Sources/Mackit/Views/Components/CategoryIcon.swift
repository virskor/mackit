import SwiftUI

/// Small category icon at the start of a row: uniform font size and placeholder width, keeping multi-line text left-aligned.
struct CategoryIcon: View {
    /// What to draw: either an SF Symbol name or a vendored brand mark.
    enum Source: Equatable, Sendable {
        case symbol(String)
        case brand(BrandLogo)
    }

    private let source: Source
    private let tint: Color
    var size: CGFloat = 13
    var width: CGFloat = 18

    init(_ source: Source, tint: Color, size: CGFloat = 13, width: CGFloat = 18) {
        self.source = source
        self.tint = tint
        self.size = size
        self.width = width
    }

    init(symbol: String, tint: Color, size: CGFloat = 13, width: CGFloat = 18) {
        self.init(.symbol(symbol), tint: tint, size: size, width: width)
    }

    init(category: JunkCategory, size: CGFloat = 13, width: CGFloat = 18) {
        self.init(category.iconSource, tint: category.tint, size: size, width: width)
    }

    var body: some View {
        switch source {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: width)
        case .brand(let logo):
            LogoMark(logo: logo, size: size)
                .foregroundStyle(tint)
                .frame(width: width)
        }
    }
}

/// A toolchain logo drawn from an SVG file bundled in Resources/BrandLogos.
/// The mark's own viewBox scales uniformly into the square slot, so any
/// aspect keeps its shape: simple-icons design their marks to optically fill
/// that box, which reads at the same weight as an SF Symbol of the same
/// nominal size. Distinct from the app's own BrandMark (the Mackit sparkle) —
/// this draws third-party logos.
private struct LogoMark: View {
    let logo: BrandLogo
    let size: CGFloat

    var body: some View {
        let box = logo.viewBox
        // Uniform scale by the longer side fits any viewBox into the slot;
        // the translation strips the viewBox origin so offsets in a future
        // non-0-based file still land centered.
        let scale = size / max(box.width, box.height)
        return Path { path in
            for element in logo.elements {
                switch element {
                case .move(let point): path.move(to: point)
                case .line(let point): path.addLine(to: point)
                case .curve(let control1, let control2, let end):
                    path.addCurve(to: end, control1: control1, control2: control2)
                case .quadCurve(let control, let end):
                    path.addQuadCurve(to: end, control: control)
                case .close: path.closeSubpath()
                }
            }
        }
        .applying(CGAffineTransform(scaleX: scale, y: scale))
        .applying(CGAffineTransform(translationX: -box.minX * scale, y: -box.minY * scale))
        // Nonzero winding, SVG's default, is also SwiftUI FillStyle's default —
        // logos with counter-shaped subpaths (the Rust gear, the Python snakes)
        // punch their holes out correctly.
        .fill()
    }
}
