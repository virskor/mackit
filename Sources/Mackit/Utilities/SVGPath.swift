import CoreGraphics

/// Minimal SVG path `d`-attribute parser covering the full command set
/// (M L H V C S Q T A Z plus their relative forms), so the vendored brand marks
/// render exactly as they do in their source SVGs.
///
/// Arcs are converted to cubic Béziers — the only curve `SwiftUI.Path` takes —
/// using the endpoint-to-center parameterization from the SVG specification
/// (appendix F.6.5), split into ≤90° segments so the approximation error stays
/// invisible at icon sizes.
///
/// Deliberately independent of SwiftUI (CoreGraphics points only) so the
/// parser can be exercised by unit tests without a graphics stack.
struct SVGPath: Sendable, Equatable {
    /// One drawing primitive, in SVG user-space coordinates (y grows downward,
    /// matching SwiftUI's coordinate system — no flip is needed when drawing).
    enum Element: Sendable, Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(control1: CGPoint, control2: CGPoint, end: CGPoint)
        case quadCurve(control: CGPoint, end: CGPoint)
        case close
    }

    /// Where parsing stopped and why. `index` is the string offset, for
    /// pinpointing a malformed vendored path during development.
    struct ParseError: Error, Equatable, Sendable {
        let message: String
        let index: Int
    }

    let elements: [Element]

    /// Everything a single-file SVG mark needs for rendering: the declared
    /// viewBox (nil when absent — the caller falls back to its own default)
    /// and the drawing commands of every `<path>` concatenated in document
    /// order. Non-path shapes (rect, circle...) are out of scope; the vendored
    /// simple-icons files are path-only, and future additions should be too.
    struct Document: Sendable, Equatable {
        var viewBox: CGRect?
        var elements: [Element]
    }

    /// Parses a whole SVG document rather than a bare `d` attribute. Attribute
    /// extraction is anchored on `<path` so look-alikes such as `id="…"` are
    /// never mistaken for drawing data.
    static func parse(document text: String) throws -> Document {
        var viewBox: CGRect?
        if let match = text.firstMatch(of: /viewBox\s*=\s*"([^"]*)"/) {
            // Both "0 0 24 24" and "0,0,24,24" are legal SVG.
            let parts = match.1.split(whereSeparator: { $0 == " " || $0 == "," })
            let numbers = try parts.map { component -> Double in
                guard let value = Double(component) else {
                    throw ParseError(message: "malformed viewBox component '\(component)'", index: 0)
                }
                return value
            }
            if numbers.count == 4 {
                viewBox = CGRect(
                    x: numbers[0], y: numbers[1],
                    width: numbers[2], height: numbers[3]
                )
            }
        }

        var elements: [Element] = []
        for match in text.matches(of: /<path\b[^>]*?\bd\s*=\s*"([^"]*)"/) {
            elements.append(contentsOf: try SVGPath.parse(String(match.1)).elements)
        }
        guard !elements.isEmpty else {
            throw ParseError(message: "no <path> element with a d attribute found", index: 0)
        }
        return Document(viewBox: viewBox, elements: elements)
    }

    static func parse(_ d: String) throws -> SVGPath {
        var elements: [Element] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // The command whose parameter group is still being consumed; after a
        // moveto, further coordinate pairs continue as an implicit lineto
        // (SVG spec section 9.3.1), which is what replacing M with L encodes.
        var pendingCommand: Unicode.Scalar?
        // Reflection anchors for the smooth commands S and T; cleared by any
        // command that breaks the reflection chain, per the spec.
        var lastCubicControl2: CGPoint?
        var lastQuadControl: CGPoint?

        let scalars = d.unicodeScalars
        var index = scalars.startIndex
        let end = scalars.endIndex

        func offset() -> Int {
            scalars.distance(from: scalars.startIndex, to: index)
        }

        func fail(_ message: String) throws -> Never {
            throw ParseError(message: message, index: offset())
        }

        func skipSeparators() {
            while index < end {
                switch scalars[index] {
                case " ", "\t", "\n", "\r", ",":
                    index = scalars.index(after: index)
                default:
                    return
                }
            }
        }

        func isCommandStart(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar {
            case "M", "m", "L", "l", "H", "h", "V", "v", "C", "c", "S", "s",
                "Q", "q", "T", "t", "A", "a", "Z", "z":
                return true
            default:
                return false
            }
        }

        /// SVG number grammar: sign? (digits ["." digits?] | "." digits)
        /// exponent?, with a second "." ending the number so the run
        /// `1.5.5` tokenizes as 1.5, 0.5.
        func parseNumber() throws -> Double {
            skipSeparators()
            guard index < end else { try fail("number expected at end of path data") }

            var text = ""
            if scalars[index] == "+" || scalars[index] == "-" {
                text.unicodeScalars.append(scalars[index])
                index = scalars.index(after: index)
            }

            var sawDigit = false
            while index < end, scalars[index] >= "0", scalars[index] <= "9" {
                text.unicodeScalars.append(scalars[index])
                index = scalars.index(after: index)
                sawDigit = true
            }
            if index < end, scalars[index] == "." {
                text.unicodeScalars.append(scalars[index])
                index = scalars.index(after: index)
                while index < end, scalars[index] >= "0", scalars[index] <= "9" {
                    text.unicodeScalars.append(scalars[index])
                    index = scalars.index(after: index)
                    sawDigit = true
                }
            }
            if sawDigit, index < end, scalars[index] == "e" || scalars[index] == "E" {
                text.unicodeScalars.append(scalars[index])
                index = scalars.index(after: index)
                if index < end, scalars[index] == "+" || scalars[index] == "-" {
                    text.unicodeScalars.append(scalars[index])
                    index = scalars.index(after: index)
                }
                var exponentDigits = false
                while index < end, scalars[index] >= "0", scalars[index] <= "9" {
                    text.unicodeScalars.append(scalars[index])
                    index = scalars.index(after: index)
                    exponentDigits = true
                }
                guard exponentDigits else { try fail("exponent without digits") }
            }

            guard sawDigit, let value = Double(text) else {
                try fail("malformed number at '\(text)'")
            }
            return value
        }

        /// An arc flag is a single character; the compact form `00` carries two
        /// flags with no separator (the Rust mark uses this).
        func parseFlag() throws -> Bool {
            skipSeparators()
            guard index < end else { try fail("arc flag expected at end of path data") }
            switch scalars[index] {
            case "0":
                index = scalars.index(after: index)
                return false
            case "1":
                index = scalars.index(after: index)
                return true
            default:
                try fail("arc flag must be 0 or 1")
            }
        }

        func absoluteTarget(x: Double, y: Double, relativeTo: CGPoint, command: Unicode.Scalar) -> CGPoint {
            if command == "M" || command == "L" || command == "C" || command == "S"
                || command == "Q" || command == "T" || command == "A" {
                return CGPoint(x: x, y: y)
            }
            return CGPoint(x: relativeTo.x + x, y: relativeTo.y + y)
        }

        while true {
            skipSeparators()
            guard index < end else { break }

            if isCommandStart(scalars[index]) {
                pendingCommand = scalars[index]
                index = scalars.index(after: index)
            } else if pendingCommand == nil {
                try fail("coordinate data before any command")
            }
            guard let command = pendingCommand else { break }

            func point(_ x: Double, _ y: Double) -> CGPoint {
                absoluteTarget(x: x, y: y, relativeTo: current, command: command)
            }

            switch command {
            case "Z", "z":
                elements.append(.close)
                current = subpathStart
                lastCubicControl2 = nil
                lastQuadControl = nil
                // A close takes no parameters; a bare number after it is malformed.
                pendingCommand = nil

            case "M", "m":
                let target = point(try parseNumber(), try parseNumber())
                elements.append(.move(target))
                current = target
                subpathStart = target
                lastCubicControl2 = nil
                lastQuadControl = nil
                pendingCommand = command == "M" ? "L" : "l"

            case "L", "l":
                let target = point(try parseNumber(), try parseNumber())
                elements.append(.line(target))
                current = target
                lastCubicControl2 = nil
                lastQuadControl = nil

            case "H", "h":
                let x = try parseNumber()
                let newX = command == "H" ? x : current.x + x
                elements.append(.line(CGPoint(x: newX, y: current.y)))
                current = CGPoint(x: newX, y: current.y)
                lastCubicControl2 = nil
                lastQuadControl = nil

            case "V", "v":
                let y = try parseNumber()
                let newY = command == "V" ? y : current.y + y
                elements.append(.line(CGPoint(x: current.x, y: newY)))
                current = CGPoint(x: current.x, y: newY)
                lastCubicControl2 = nil
                lastQuadControl = nil

            case "C", "c":
                let control1 = point(try parseNumber(), try parseNumber())
                let control2 = point(try parseNumber(), try parseNumber())
                let target = point(try parseNumber(), try parseNumber())
                elements.append(.curve(control1: control1, control2: control2, end: target))
                current = target
                lastCubicControl2 = control2
                lastQuadControl = nil

            case "S", "s":
                let control2 = point(try parseNumber(), try parseNumber())
                let target = point(try parseNumber(), try parseNumber())
                let control1 = lastCubicControl2.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                elements.append(.curve(control1: control1, control2: control2, end: target))
                current = target
                lastCubicControl2 = control2
                lastQuadControl = nil

            case "Q", "q":
                let control = point(try parseNumber(), try parseNumber())
                let target = point(try parseNumber(), try parseNumber())
                elements.append(.quadCurve(control: control, end: target))
                current = target
                lastQuadControl = control
                lastCubicControl2 = nil

            case "T", "t":
                let target = point(try parseNumber(), try parseNumber())
                let control = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                elements.append(.quadCurve(control: control, end: target))
                current = target
                lastQuadControl = control
                lastCubicControl2 = nil

            case "A", "a":
                let rx = try parseNumber()
                let ry = try parseNumber()
                let rotation = try parseNumber()
                let largeArc = try parseFlag()
                let sweep = try parseFlag()
                let target = point(try parseNumber(), try parseNumber())
                appendArc(
                    from: current, to: target,
                    rx: rx, ry: ry, rotationDegrees: rotation,
                    largeArc: largeArc, sweep: sweep,
                    to: &elements
                )
                current = target
                lastCubicControl2 = nil
                lastQuadControl = nil

            default:
                // isCommandStart only admits the letters handled above.
                break
            }
        }

        return SVGPath(elements: elements)
    }

    /// Converts one elliptical arc segment into cubic Béziers, following the
    /// SVG specification appendix F.6 (endpoint to center parameterization).
    private static func appendArc(
        from start: CGPoint, to end: CGPoint,
        rx inputRx: Double, ry inputRy: Double, rotationDegrees: Double,
        largeArc: Bool, sweep: Bool,
        to elements: inout [Element]
    ) {
        // Zero radii degrade to a straight line (spec F.6.2), and the flags
        // then carry no geometric meaning.
        guard inputRx != 0, inputRy != 0 else {
            elements.append(.line(end))
            return
        }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        // F.6.5.1: move the origin to the chord midpoint and rotate so the
        // ellipse becomes axis-aligned.
        let halfDX = (start.x - end.x) / 2
        let halfDY = (start.y - end.y) / 2
        let x1p = cosPhi * halfDX + sinPhi * halfDY
        let y1p = -sinPhi * halfDX + cosPhi * halfDY

        // F.6.6: scale radii up when they are too small for the chord.
        var rx = abs(inputRx)
        var ry = abs(inputRy)
        let radiusScale = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
        if radiusScale > 1 {
            let factor = sqrt(radiusScale)
            rx *= factor
            ry *= factor
        }

        // F.6.5.2: locate the center; the sign chooses between the two
        // candidate arcs so the flags select the intended one.
        let sign: Double = largeArc != sweep ? 1 : -1
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coefficient = sign * sqrt(max(0, numerator / denominator))
        let centerXP = coefficient * rx * y1p / ry
        let centerYP = -coefficient * ry * x1p / rx
        let centerX = cosPhi * centerXP - sinPhi * centerYP + (start.x + end.x) / 2
        let centerY = sinPhi * centerXP + cosPhi * centerYP + (start.y + end.y) / 2

        func angle(_ x: Double, _ y: Double) -> Double {
            atan2(y, x)
        }

        var theta = angle((x1p - centerXP) / rx, (y1p - centerYP) / ry)
        var deltaTheta = angle((-x1p - centerXP) / rx, (-y1p - centerYP) / ry) - theta
        if !sweep, deltaTheta > 0 { deltaTheta -= 2 * .pi }
        if sweep, deltaTheta < 0 { deltaTheta += 2 * .pi }

        func onEllipse(_ theta: Double) -> CGPoint {
            CGPoint(
                x: centerX + rx * cos(theta) * cosPhi - ry * sin(theta) * sinPhi,
                y: centerY + rx * cos(theta) * sinPhi + ry * sin(theta) * cosPhi
            )
        }

        // Tangent of the parameterized ellipse; the Bézier handles extend from
        // each endpoint along it.
        func tangent(_ theta: Double) -> CGPoint {
            CGPoint(
                x: -rx * sin(theta) * cosPhi - ry * cos(theta) * sinPhi,
                y: -rx * sin(theta) * sinPhi + ry * cos(theta) * cosPhi
            )
        }

        let segmentCount = max(1, Int(ceil(abs(deltaTheta) / (.pi / 2))))
        let step = deltaTheta / Double(segmentCount)
        let handle = 4.0 / 3.0 * tan(step / 4)

        for _ in 0..<segmentCount {
            let nextTheta = theta + step
            let start_ = onEllipse(theta)
            let end_ = onEllipse(nextTheta)
            let startTangent = tangent(theta)
            let endTangent = tangent(nextTheta)
            elements.append(.curve(
                control1: CGPoint(x: start_.x + handle * startTangent.x, y: start_.y + handle * startTangent.y),
                control2: CGPoint(x: end_.x - handle * endTangent.x, y: end_.y - handle * endTangent.y),
                end: end_
            ))
            theta = nextTheta
        }
    }
}
