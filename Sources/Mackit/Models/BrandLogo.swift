import Foundation

/// Official brand marks for the developer-tool categories. Each case carries
/// the logo of the toolchain its category cleans up, so the sidebar shows the
/// real mark (the Go wordmark, the Node.js hexagon, ...) instead of a generic
/// SF Symbol that could stand for anything.
///
/// The marks live as plain SVG files in `Resources/BrandLogos/`, vendored
/// verbatim from simple-icons (https://simpleicons.org) — file names are the
/// upstream slugs so a refresh is a byte-for-byte file replacement with no
/// codegen step. Upstream's repository is CC0-licensed; the marks themselves
/// remain trademarks of their respective owners and are used nominatively, to
/// label a cache category with the logo of the very toolchain it belongs to.
/// See that folder's README for the update procedure.
enum BrandLogo: String, CaseIterable, Sendable {
    case go, node, flutter, rust, python, android, xcode, pods, homebrew

    /// Bundled file name, kept at the upstream slug rather than the case name
    /// so the file can be diffed against a fresh simple-icons download.
    var resourceSlug: String {
        switch self {
        case .node: return "nodedotjs"
        case .pods: return "cocoapods"
        default: return rawValue
        }
    }

    /// Drawing commands of the mark. Empty when the bundled SVG could not be
    /// loaded or parsed — the icon then draws nothing rather than crashing.
    var elements: [SVGPath.Element] {
        Self.loaded[self]?.elements ?? []
    }

    /// The mark's own coordinate system from its `viewBox`; falls back to the
    /// simple-icons 24×24 box when the file declares none.
    var viewBox: CGRect {
        Self.loaded[self]?.viewBox ?? CGRect(x: 0, y: 0, width: 24, height: 24)
    }

    /// Loaded once on first access (atomic static initialization) so
    /// re-rendering the sidebar never re-reads or re-parses the files.
    private static let loaded: [BrandLogo: SVGPath.Document] = {
        var map: [BrandLogo: SVGPath.Document] = [:]
        for logo in allCases {
            guard let url = Bundle.module.url(
                forResource: logo.resourceSlug, withExtension: "svg"
            ) else {
                MackitLog.ui.error("Brand logo SVG missing from bundle: \(logo.resourceSlug, privacy: .public)")
                continue
            }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                map[logo] = try SVGPath.parse(document: text)
            } catch {
                MackitLog.ui.error("Brand logo \(logo.resourceSlug, privacy: .public) failed to load: \(String(describing: error), privacy: .public)")
            }
        }
        return map
    }()
}
