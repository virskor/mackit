import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Generate the DMG installation background image: a deep blue gradient base,
// an "app → Applications" install arrow, and hint text.
// The real Mackit.app and Applications icons are drawn by Finder on top of this
// image, so the background does not draw the icons themselves, leaving only the
// arrow and the text.
//
// The dimensions and coordinates are strict; before changing them, first check
// the corresponding values in the Finder layout in build-dmg.sh:
//   - Finder scales the background image according to the PNG's pHYs DPI. With
//     144 DPI written, this 1440x744 image is displayed at exactly 720x372
//     points, matching the window content area in size — 1 image pixel maps to
//     1 screen pixel on Retina, so the arrow and text are sharp.
//   - Without pHYs, Finder displays the whole image at 1 pixel = 1 point, so
//     only the top-left 720x372 pixels are visible and everything drawn below
//     is cropped off (measured result).
//   - Finder coordinates (icon positions, arrow, text) use the top-left of the
//     content area as the origin; CG's y-axis points up, so subtract from the
//     canvas height when converting.
// Usage: swift Scripts/make-dmg-background.swift <output .png>

let logicalWidth: CGFloat = 720
let logicalHeight: CGFloat = 372
let scale: CGFloat = 2
let dpi = 144

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("make-dmg-background failed: \(message)\n".data(using: .utf8)!)
    exit(1)
}

extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

// PNG's CRC32 (the same polynomial as zlib's parameters)
func pngCRC32(_ data: Data) -> UInt32 {
    var table: [UInt32] = []
    for n in 0..<256 {
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
        }
        table.append(c)
    }
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFFFFFF
}

// Insert a pHYs chunk after IHDR, declaring the image's physical resolution
// (pixels per meter). Finder then displays the image at its logical size
// instead of 1 pixel = 1 point.
func insertPhysChunk(path: String, dpi: Int) throws {
    var data = try Data(contentsOf: URL(fileURLWithPath: path))
    // 8-byte file header + IHDR chunk (4 length + 4 type + 13 data + 4 CRC)
    let ihdrEnd = data.index(data.startIndex, offsetBy: 8 + 25)
    guard data.count >= ihdrEnd else { return }

    let pixelsPerMeter = UInt32((Double(dpi) / 0.0254).rounded())
    var payload = Data()
    payload.appendUInt32BE(pixelsPerMeter)
    payload.appendUInt32BE(pixelsPerMeter)
    payload.append(1) // Unit: meter

    var chunk = Data()
    chunk.appendUInt32BE(UInt32(payload.count))
    let typeAndData = Data("pHYs".utf8) + payload
    chunk.append(typeAndData)
    chunk.appendUInt32BE(pngCRC32(typeAndData))

    data.insert(contentsOf: chunk, at: ihdrEnd)
    try data.write(to: URL(fileURLWithPath: path))
}

let pixelWidth = Int(logicalWidth * scale)
let pixelHeight = Int(logicalHeight * scale)
let colorSpace = CGColorSpaceCreateDeviceRGB()

guard let context = CGContext(
    data: nil,
    width: pixelWidth,
    height: pixelHeight,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fail("Cannot create the canvas")
}
context.scaleBy(x: scale, y: scale)

// Base color: a linear gradient from deep blue at the top to navy at the bottom
guard let base = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.07, green: 0.23, blue: 0.45, alpha: 1),
        CGColor(red: 0.01, green: 0.06, blue: 0.15, alpha: 1)
    ] as CFArray,
    locations: [0, 1]
) else {
    fail("Cannot create the base gradient")
}
context.drawLinearGradient(
    base,
    start: CGPoint(x: 0, y: logicalHeight),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// Soft glow in the top-left, using the icon's color family to keep the background from looking rigid
if let glow = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(red: 0.31, green: 0.85, blue: 0.98, alpha: 0.22),
        CGColor(red: 0.31, green: 0.85, blue: 0.98, alpha: 0)
    ] as CFArray,
    locations: [0, 1]
) {
    let center = CGPoint(x: logicalWidth * 0.24, y: logicalHeight * 0.72)
    context.drawRadialGradient(
        glow,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: 400,
        options: [.drawsAfterEndLocation]
    )
}

// One hand-drawn stroke: a quadratic segment with round caps. The bow comes
// from where the control point sits — above both endpoints the stroke flicks
// up as it leaves and settles as it arrives, which no straight line does.
func strokeHandCurve(
    _ context: CGContext,
    from start: CGPoint,
    control: CGPoint,
    to end: CGPoint,
    width: CGFloat,
    alpha: CGFloat
) {
    let path = CGMutablePath()
    path.move(to: start)
    path.addQuadCurve(to: end, control: control)
    context.setLineWidth(width)
    context.setStrokeColor(CGColor(gray: 1, alpha: alpha))
    context.addPath(path)
    context.strokePath()
}

// Install arrow, drawn the way a marker draws it: spans the gap between the
// two icons. Finder places the app at {165,150} and Applications at {555,150}
// with an icon size of 108 — converted to CG coordinates (origin at the
// bottom-left), the arrow's center line is at y=168, the vertical center of
// the icon band.
let arrowY = logicalHeight - 204
context.setLineCap(.round)

// Shaft, first pass: leaves the app icon with a slight upward flick, bows up
// about 5pt at mid-span, and arrives level at the head's base.
strokeHandCurve(
    context,
    from: CGPoint(x: 292, y: arrowY),
    control: CGPoint(x: 397, y: arrowY + 10),
    to: CGPoint(x: 502, y: arrowY),
    width: 5,
    alpha: 0.55
)
// Second pass: a marker going back over the start of the line without matching
// it — flatter, a few points lower, thinner, lighter, and stopping partway.
strokeHandCurve(
    context,
    from: CGPoint(x: 296, y: arrowY - 3),
    control: CGPoint(x: 362, y: arrowY + 1),
    to: CGPoint(x: 430, y: arrowY - 2),
    width: 3.5,
    alpha: 0.28
)

// Head: an open V of two strokes rather than a filled triangle — each barb
// leaves the shaft's base bowing outward and overshoots the tip, which is what
// makes it read as drawn instead of plotted.
strokeHandCurve(
    context,
    from: CGPoint(x: 502, y: arrowY + 16),
    control: CGPoint(x: 525, y: arrowY + 13),
    to: CGPoint(x: 542, y: arrowY - 1),
    width: 5,
    alpha: 0.55
)
strokeHandCurve(
    context,
    from: CGPoint(x: 502, y: arrowY - 16),
    control: CGPoint(x: 525, y: arrowY - 13),
    to: CGPoint(x: 542, y: arrowY + 1),
    width: 5,
    alpha: 0.55
)

// Install hint text. Uses CFAttributedString + CoreText attribute keys instead
// of NSAttributedString.Key: in a command-line swift script the latter's
// members are unavailable.
// When the font name is not found, CoreText falls back to the system font,
// which does not affect rendering.
let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(
    nil,
    "Drag Mackit to Applications" as CFString,
    [
        kCTFontAttributeName: CTFontCreateWithName("PingFangSC-Medium" as CFString, 13, nil),
        kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 0.85)
    ] as CFDictionary
))
let bounds = CTLineGetBoundsWithOptions(line, [])
context.textPosition = CGPoint(
    x: (logicalWidth - bounds.width) / 2 - bounds.origin.x,
    y: 32 - bounds.origin.y
)
CTLineDraw(line, context)

guard let image = context.makeImage() else {
    fail("Rendering failed")
}
guard let destination = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: outputPath) as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fail("Cannot create \(outputPath)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("Failed to write \(outputPath)")
}

// ImageIO does not write DPI for PNG, so pHYs is added manually: without it
// Finder displays the whole image at 1 pixel = 1 point, and content below the
// canvas gets cropped.
do {
    try insertPhysChunk(path: outputPath, dpi: dpi)
} catch {
    fail("Failed to insert pHYs: \(error.localizedDescription)")
}

print("Generated DMG background image: \(outputPath) (\(logicalWidth)x\(logicalHeight) @\(dpi)dpi)")
