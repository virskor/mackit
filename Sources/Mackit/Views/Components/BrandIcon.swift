import AppKit
import SwiftUI

/// Brand icon for in-app display: a blue double star (frosted main star + blue back star).
///
/// The image itself is `Sources/Mackit/Resources/sparkle-blue.png` (1024×1024, with an
/// alpha channel), which SPM packs into Mackit_Mackit.bundle and which is fetched here
/// via Bundle.module. It is a rasterized copy of the SVG in the `Assets/sparkle/`
/// workspace—when changing the icon, re-render and overwrite this file; the same asset
/// is used by `Scripts/make-icon.swift` to generate the app icon.
///
/// Used only in interfaces with a background (the About page, the tray panel, the
/// welcome page, the sidebar footer). The menu bar status item uses MenuBarIcon's
/// monochrome template image: there it must automatically turn black or white
/// following the menu bar's light/dark appearance, whereas a full-color image
/// would blur into a mess in the menu bar. Rendering goes through BrandMark, so
/// the asset is drawn one way everywhere it appears.
///
/// Read-only after initialization; Swift guarantees lazy initialization runs only once
/// (thread-safe). NSImage is already marked Sendable in the current SDK, so no exemption
/// is needed; the fellow global constant MenuBarStarPath holds a CGPath (not Sendable),
/// which is where nonisolated(unsafe) is actually needed.
enum BrandIcon {
    static let image: NSImage? = Bundle.module
        .url(forResource: "sparkle-blue", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
}
