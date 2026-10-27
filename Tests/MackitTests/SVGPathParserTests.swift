import CoreGraphics
import Testing

@testable import Mackit

/// The parser behind the vendored brand marks: geometry correctness for the
/// command set the marks actually use, and a pin on every vendored path so a
/// bad paste in `BrandLogo` cannot ship silently.
struct SVGPathParserTests {
    private func parse(_ d: String) throws -> [SVGPath.Element] {
        try SVGPath.parse(d).elements
    }

    private func points(in elements: [SVGPath.Element]) -> [CGPoint] {
        elements.flatMap { element -> [CGPoint] in
            switch element {
            case .move(let p): return [p]
            case .line(let p): return [p]
            case .curve(let c1, let c2, let end): return [c1, c2, end]
            case .quadCurve(let c, let end): return [c, end]
            case .close: return []
            }
        }
    }

    /// The points that lie on the drawn geometry — curve and quad *endpoints*
    /// included, control points excluded. A Bézier control point routinely
    /// sits outside the convex hull of its own curve (the vendored ruby mark
    /// has one at y = -0.548 against a 0..24 box while every point of the
    /// rendered curve stays inside), so the box confinement below is checked
    /// against these rather than against every parsed coordinate.
    private func anchoredPoints(in elements: [SVGPath.Element]) -> [CGPoint] {
        elements.flatMap { element -> [CGPoint] in
            switch element {
            case .move(let p): return [p]
            case .line(let p): return [p]
            case .curve(_, _, let end): return [end]
            case .quadCurve(_, let end): return [end]
            case .close: return []
            }
        }
    }

    @Test func movelineAndClose() throws {
        #expect(try parse("M1 1L2 2Z") == [
            .move(CGPoint(x: 1, y: 1)),
            .line(CGPoint(x: 2, y: 2)),
            .close,
        ])
    }

    /// Coordinate pairs following a moveto continue as an implicit lineto.
    @Test func implicitLinetoAfterMoveto() throws {
        #expect(try parse("M1 1 2 2 3 3") == [
            .move(CGPoint(x: 1, y: 1)),
            .line(CGPoint(x: 2, y: 2)),
            .line(CGPoint(x: 3, y: 3)),
        ])
    }

    @Test func relativeCommandsAccumulate() throws {
        #expect(try parse("m1 1l1 1 2 0") == [
            .move(CGPoint(x: 1, y: 1)),
            .line(CGPoint(x: 2, y: 2)),
            .line(CGPoint(x: 4, y: 2)),
        ])
    }

    @Test func horizontalAndVerticalLines() throws {
        #expect(try parse("M1 1H4v3h-2") == [
            .move(CGPoint(x: 1, y: 1)),
            .line(CGPoint(x: 4, y: 1)),
            .line(CGPoint(x: 4, y: 4)),
            .line(CGPoint(x: 2, y: 4)),
        ])
    }

    /// S reflects the previous curve's second control point about the current
    /// point: here 2·(3,0) − (2,1) = (4,−1).
    @Test func smoothCubicReflectsControlPoint() throws {
        #expect(try parse("M0 0C1 1 2 1 3 0S5 -1 6 0") == [
            .move(CGPoint(x: 0, y: 0)),
            .curve(control1: CGPoint(x: 1, y: 1), control2: CGPoint(x: 2, y: 1), end: CGPoint(x: 3, y: 0)),
            .curve(control1: CGPoint(x: 4, y: -1), control2: CGPoint(x: 5, y: -1), end: CGPoint(x: 6, y: 0)),
        ])
    }

    /// A smooth cubic with no preceding curve has no reflection anchor and
    /// takes the current point as its first control.
    @Test func smoothCubicWithoutAnchorUsesCurrentPoint() throws {
        #expect(try parse("M1 2S3 4 5 6") == [
            .move(CGPoint(x: 1, y: 2)),
            .curve(control1: CGPoint(x: 1, y: 2), control2: CGPoint(x: 3, y: 4), end: CGPoint(x: 5, y: 6)),
        ])
    }

    /// T reflects the previous quadratic control point: 2·(2,0) − (1,−2) = (3,2).
    @Test func smoothQuadReflectsControlPoint() throws {
        #expect(try parse("M0 0Q1 -2 2 0T4 0") == [
            .move(CGPoint(x: 0, y: 0)),
            .quadCurve(control: CGPoint(x: 1, y: -2), end: CGPoint(x: 2, y: 0)),
            .quadCurve(control: CGPoint(x: 3, y: 2), end: CGPoint(x: 4, y: 0)),
        ])
    }

    /// A semicircle is split into two 90° segments. The on-curve points stay
    /// on the source circle and the arc reaches its endpoint; each control
    /// sits at the canonical κ·r handle distance from its segment endpoint —
    /// the property a cubic circle approximation is measured by. Controls are
    /// necessarily off the circle itself, so asserting they were on it would
    /// fail every correct approximation.
    @Test func arcBecomesTwoCubicsOnTheCircle() throws {
        let elements = try parse("M0 0A5 5 0 0 1 10 0")
        guard case .curve = elements[1], case .curve = elements[2] else {
            Issue.record("expected two cubic segments, got \(elements)")
            return
        }
        #expect(elements.count == 3)

        let center = CGPoint(x: 5, y: 0)
        func radius(of point: CGPoint) -> Double {
            let dx = point.x - center.x
            let dy = point.y - center.y
            return (dx * dx + dy * dy).squareRoot()
        }

        // The endpoint carries float noise (θ reaches 2π), so the reach is
        // asserted within tolerance rather than exactly.
        let last = try #require(points(in: elements).last)
        #expect(abs(last.x - 10) < 1e-9 && abs(last.y) < 1e-9)

        var onCurve: [CGPoint] = []
        var controls: [(control: CGPoint, anchor: CGPoint)] = []
        for element in elements {
            switch element {
            case .move(let p):
                onCurve.append(p)
            case .curve(let c1, let c2, let end):
                onCurve.append(end)
                controls.append((c1, onCurve[onCurve.count - 2]))
                controls.append((c2, end))
            default:
                Issue.record("unexpected element \(element)")
            }
        }
        for point in onCurve {
            #expect(abs(radius(of: point) - 5) < 0.01, "\(point) is off the circle")
        }

        let kappa = 4.0 / 3.0 * tan(.pi / 8)
        for (control, anchor) in controls {
            let dx = control.x - anchor.x
            let dy = control.y - anchor.y
            let reach = (dx * dx + dy * dy).squareRoot()
            #expect(abs(reach - kappa * 5) < 0.01, "\(control) handle is not at κ·r from \(anchor)")
        }
    }

    /// Arc flags may run together with no separator: `015 5` is flags 0, 1
    /// followed by dx, dy — the compact form the Rust and Homebrew marks use.
    @Test func arcFlagsParseWithoutSeparators() throws {
        let elements = try parse("M0 0a5 5 0 015 5")
        #expect(elements.count == 2)  // move + the converted arc
        #expect(points(in: elements).last == CGPoint(x: 5, y: 5))
    }

    /// A dot starts a new number, so `1.5.5` is 1.5 then 0.5; a minus sign
    /// does the same, so `-.5-.5` is two copies of −0.5.
    @Test func numbersWithoutSeparators() throws {
        #expect(try parse("M1.5.5l.5-.5") == [
            .move(CGPoint(x: 1.5, y: 0.5)),
            .line(CGPoint(x: 2, y: 0)),
        ])
    }

    /// Close returns the current point to the subpath start, so a relative
    /// move after a close is relative to that start.
    @Test func closeRestoresSubpathStart() throws {
        let elements = try parse("M1 1L5 5Zm1 0h2")
        #expect(elements == [
            .move(CGPoint(x: 1, y: 1)),
            .line(CGPoint(x: 5, y: 5)),
            .close,
            .move(CGPoint(x: 2, y: 1)),
            .line(CGPoint(x: 4, y: 1)),
        ])
    }

    @Test func malformedDataThrows() {
        #expect(throws: SVGPath.ParseError.self) { try SVGPath.parse("5 5L1 1") }
        #expect(throws: SVGPath.ParseError.self) { try SVGPath.parse("M1") }
        #expect(throws: SVGPath.ParseError.self) { try SVGPath.parse("M0 0A5 5 0 2 1 10 0") }
        #expect(throws: SVGPath.ParseError.self) { try SVGPath.parse("M0 0Z1") }
    }

    /// An arc whose endpoints coincide has no geometry to draw: the spec
    /// (F.4) omits the segment entirely rather than collapsing it, and the
    /// center equation (F.6.5.2) would divide by zero for it. The path must
    /// keep drawing from the untouched current point, with no NaN smuggled
    /// in as a coordinate.
    @Test func degenerateArcIsOmitted() throws {
        #expect(try parse("M0 0A5 5 0 0 1 0 0L4 4") == [
            .move(CGPoint(x: 0, y: 0)),
            .line(CGPoint(x: 4, y: 4)),
        ])
    }

    /// Every bundled mark must decode: non-empty, anchored by a moveto, with
    /// a declared viewBox confining the drawn geometry. A truncated or
    /// corrupted SVG fails here instead of shipping a broken icon.
    ///
    /// Two properties the original nine marks happened to share are
    /// deliberately not required: a final `Z`, which upstream marks are free
    /// to omit (clojure and perl leave their last subpath open, and SVG
    /// fill closes it implicitly — they render as upstream draws them), and
    /// control-point containment, which Béziers do not promise (see
    /// `anchoredPoints`).
    @Test func everyBundledBrandLogoDecodesInsideItsViewBox() throws {
        #expect(!BrandLogo.allCases.isEmpty)
        for logo in BrandLogo.allCases {
            let elements = logo.elements

            #expect(!elements.isEmpty, "\(logo.rawValue) loaded no elements")
            #expect(elements.first?.isMove == true, "\(logo.rawValue) does not start with a moveto")

            let box = logo.viewBox
            #expect(box.width > 0 && box.height > 0, "\(logo.rawValue) has no usable viewBox")

            for point in anchoredPoints(in: elements) {
                #expect(point.x >= box.minX - 0.5 && point.x <= box.maxX + 0.5,
                        "\(logo.rawValue) x \(point.x) outside the viewBox")
                #expect(point.y >= box.minY - 0.5 && point.y <= box.maxY + 0.5,
                        "\(logo.rawValue) y \(point.y) outside the viewBox")
            }
        }
    }

    /// Document parsing: the viewBox is carried through, multiple `<path>`
    /// elements concatenate in order, and look-alike attributes such as
    /// `id="…"` are never mistaken for drawing data.
    @Test func documentParsing() throws {
        let document = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 32">
              <title>Test</title>
              <rect id="frame" width="48" height="32"/>
              <path d="M1 1L5 5"/>
              <path fill="none" stroke-dasharray="2" d="M7 1C8 2 9 3 10 4"/>
            </svg>
            """
        let parsed = try SVGPath.parse(document: document)
        #expect(parsed.viewBox == CGRect(x: 0, y: 0, width: 48, height: 32))
        #expect(parsed.elements == [
            .move(CGPoint(x: 1, y: 1)),
            .line(CGPoint(x: 5, y: 5)),
            .move(CGPoint(x: 7, y: 1)),
            .curve(control1: CGPoint(x: 8, y: 2), control2: CGPoint(x: 9, y: 3), end: CGPoint(x: 10, y: 4)),
        ])
    }

    @Test func documentWithoutPathsThrows() {
        #expect(throws: SVGPath.ParseError.self) {
            try SVGPath.parse(document: "<svg viewBox=\"0 0 24 24\"><rect width=\"24\" height=\"24\"/></svg>")
        }
    }

    /// Every category carrying a brand resolves to it; every other category
    /// keeps its SF Symbol. The map is the whitelist of branded categories —
    /// it grows with every ecosystem that vendors a mark.
    @Test func categoryIconSourcesResolveBrandThenSymbol() {
        let branded: [JunkCategory: BrandLogo] = [
            .xcode: .xcode, .android: .android, .go: .go, .node: .node,
            .flutter: .flutter, .rust: .rust, .python: .python,
            .ruby: .ruby, .php: .php, .dotnet: .dotnet, .scala: .scala,
            .haskell: .haskell, .clojure: .clojure, .elixir: .elixir,
            .lua: .lua, .julia: .julia, .ocaml: .ocaml, .zig: .zig,
            .nim: .nim, .crystal: .crystal, .perl: .perl,
            .pods: .pods, .homebrew: .homebrew,
        ]
        for category in JunkCategory.allCases {
            if let expected = branded[category] {
                #expect(category.iconSource == .brand(expected))
            } else {
                #expect(category.iconSource == .symbol(category.symbol))
            }
        }
    }
}

extension SVGPath.Element {
    var isMove: Bool {
        if case .move = self { return true }
        return false
    }
}
