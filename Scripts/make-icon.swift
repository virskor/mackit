import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Generate Mackit's app icon: a dark gradient rounded card + a frosted-glass
// double star (blue version).
// The stars are composited directly from Assets/sparkle/sparkle-blue-1024.png
// — that PNG was rasterized natively from the SVG by Chrome, preserving the
// gradient, blur and highlights, which is more faithful than redrawing it with
// CGPath.
// Usage: swift Scripts/make-icon.swift <output .iconset directory>

let canvas: CGFloat = 1024

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

/// The star source image: Sources/Mackit/Resources/sparkle-blue.png in the
/// repository. This is also the image shown in the in-app About page / tray
/// panel / welcome page (fetched via Bundle.module), so one copy serves both
/// purposes; it is the rasterized product of the SVG in the Assets/sparkle/
/// workspace — when changing the icon, re-render and overwrite it here.
let sparkleURL = URL(fileURLWithPath: #file)
    .deletingLastPathComponent()   // Scripts
    .deletingLastPathComponent()   // Repository root directory
    .appendingPathComponent("Sources/Mackit/Resources/sparkle-blue.png")

let sparkleImage: CGImage? = {
    guard let source = CGImageSourceCreateWithURL(sparkleURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    return image
}()

func savePNG(_ image: CGImage, size: Int, name: String) throws {
    let url = URL(fileURLWithPath: "\(outputDir)/\(name)")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 \(name)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "写入 \(name) 失败"])
    }
}

func render(size: CGFloat) -> CGImage? {
    let scale = size / canvas
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.scaleBy(x: scale, y: scale)

    // Background rounded square: keeps the card style of the original icon
    // (inset 12 + continuous corners), so changing the icon does not alter the
    // frame, and the shape recognition in the Dock stays the same.
    let inset: CGFloat = 12
    let rect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius: CGFloat = canvas * 0.235
    let backgroundPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    context.saveGState()
    context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)

    // Vertical gradient from deep indigo to near-black: the frosted-glass stars
    // are filled with a translucent gradient, which only reads as "frosted" on a
    // sufficiently dark base; the original icon's bright cyan blue would wash out
    // the white stars.
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 0.18, green: 0.30, blue: 0.55, alpha: 1),
        CGColor(red: 0.04, green: 0.07, blue: 0.16, alpha: 1)
    ] as CFArray, locations: [0, 1]) else {
        return nil
    }
    context.addPath(backgroundPath)
    context.clip()
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: canvas / 2, y: canvas - inset),
        end: CGPoint(x: canvas / 2, y: inset),
        options: []
    )

    // Soft glow in the top-left corner, adding depth (a bit more restrained
    // than the original icon, so it does not fight with the stars' highlights)
    if let gloss = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0)
    ] as CFArray, locations: [0, 1]) {
        context.drawRadialGradient(
            gloss,
            startCenter: CGPoint(x: canvas * 0.28, y: canvas * 0.74),
            startRadius: 0,
            endCenter: CGPoint(x: canvas * 0.28, y: canvas * 0.74),
            endRadius: canvas * 0.78,
            options: []
        )
    }

    // The double-star icon is centered and occupies 66% of the canvas: the
    // macOS icon safe area is about 80%, so leaving enough margin means it is
    // not cropped by the system when scaled down to 16px.
    guard let sparkle = sparkleImage else { return nil }
    let iconSize = canvas * 0.66
    let iconRect = CGRect(
        x: (canvas - iconSize) / 2,
        y: (canvas - iconSize) / 2,
        width: iconSize,
        height: iconSize
    )
    context.draw(sparkle, in: iconRect)

    context.endTransparencyLayer()
    context.restoreGState()

    return context.makeImage()
}

do {
    if sparkleImage == nil {
        throw NSError(
            domain: "make-icon", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "读不到星星源图 \(sparkleURL.path)，确认文件存在"]
        )
    }
    try FileManager.default.createDirectory(
        atPath: outputDir,
        withIntermediateDirectories: true,
        attributes: nil
    )

    // All sizes required by the macOS icon set
    let specs: [(Int, String)] = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png")
    ]

    var cache: [Int: CGImage] = [:]
    for (size, name) in specs {
        if cache[size] == nil {
            cache[size] = render(size: CGFloat(size))
        }
        guard let image = cache[size] else {
            throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "渲染 \(size)px 失败"])
        }
        try savePNG(image, size: size, name: name)
    }
    print("已生成图标集：\(outputDir)")
} catch {
    FileHandle.standardError.write("make-icon 失败：\(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
