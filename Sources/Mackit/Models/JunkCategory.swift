import SwiftUI

/// Major category a cleanup item belongs to; the sidebar groups by this.
enum JunkCategory: String, CaseIterable, Identifiable, Sendable {
    case apps
    case projects
    case xcode
    case simulator
    case android
    case go
    case node
    case flutter
    case rust
    case python
    case pods
    case ide
    case browser
    case language
    case downloads
    case homebrew
    case system
    case trash

    var id: String { rawValue }

    /// Localization key prefix; the actual text lives in Localizable.xcstrings.
    private var key: String { "category.\(rawValue)" }

    var title: String {
        L10n.tr("\(key).title")
    }

    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2.fill"
        case .projects: return "folder.fill.badge.gearshape"
        case .xcode: return "hammer.fill"
        case .simulator: return "apps.iphone"
        case .android: return "cube.fill"
        case .go: return "arrow.triangle.branch"
        case .node: return "square.stack.3d.up.fill"
        case .flutter: return "leaf.fill"
        case .rust: return "gearshape.2"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .pods: return "shippingbox.fill"
        case .ide: return "puzzlepiece.extension.fill"
        case .browser: return "globe"
        case .language: return "character.book.closed.fill"
        case .downloads: return "tray.and.arrow.down.fill"
        case .homebrew: return "mug.fill"
        case .system: return "internaldrive.fill"
        case .trash: return "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        // The other categories already use up all the semantic colors; apps use black/white adaptive color to stay neutral
        case .apps: return .primary
        case .projects: return .indigo
        case .xcode: return .blue
        case .simulator: return .purple
        case .android: return .green
        case .go: return .cyan
        case .node: return .mint
        case .flutter: return .teal
        case .rust: return .orange
        case .python: return .yellow
        case .pods: return .brown
        case .ide: return .pink
        case .browser: return .blue
        case .language: return .mint
        case .downloads: return .orange
        case .homebrew: return .red
        case .system: return .gray
        case .trash: return .secondary
        }
    }

    /// One-line description of what this category cleans up.
    var summary: String {
        L10n.tr("\(key).summary")
    }

    var sortOrder: Int {
        switch self {
        case .apps: return 0
        case .projects: return 1
        case .xcode: return 2
        case .simulator: return 3
        case .android: return 4
        case .node: return 5
        case .flutter: return 6
        case .go: return 7
        case .rust: return 8
        case .python: return 9
        case .pods: return 10
        case .ide: return 11
        case .browser: return 12
        case .language: return 13
        case .downloads: return 14
        case .homebrew: return 15
        case .system: return 16
        case .trash: return 17
        }
    }

    static let ordered: [JunkCategory] = allCases.sorted { $0.sortOrder < $1.sortOrder }

    /// Which cleanup feature this category belongs to. The two audiences never
    /// share a category: toolchain caches are meaningless to a general user,
    /// and browser junk is noise to a developer mid-build. The partition also
    /// guarantees no path is cleaned by both features.
    var scope: CleanupScope {
        switch self {
        case .apps, .projects, .xcode, .simulator, .android, .go, .node, .flutter, .rust, .python, .pods, .ide, .homebrew:
            return .developer
        case .browser, .language, .downloads, .system, .trash:
            return .general
        }
    }
}
