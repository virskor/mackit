import SwiftUI

/// Major category a cleanup item belongs to; the sidebar groups by this.
enum JunkCategory: String, CaseIterable, Identifiable, Sendable {
    case apps
    case appJunk
    case projects
    case xcode
    case simulator
    case android
    case go
    case node
    case flutter
    case rust
    case python
    case ruby
    case php
    case dotnet
    case scala
    case haskell
    case clojure
    case elixir
    case lua
    case julia
    case ocaml
    case zig
    case nim
    case crystal
    case perl
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
        case .appJunk: return "square.stack.3d.up.fill"
        case .projects: return "folder.fill.badge.gearshape"
        case .xcode: return "hammer.fill"
        case .simulator: return "apps.iphone"
        case .android: return "cube.fill"
        case .go: return "arrow.triangle.branch"
        case .node: return "square.stack.3d.up.fill"
        case .flutter: return "leaf.fill"
        case .rust: return "gearshape.2"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .ruby: return "seal.fill"
        case .php: return "server.rack"
        case .dotnet: return "square.stack.3d.up.fill"
        case .scala: return "scalemass.fill"
        case .haskell: return "function"
        case .clojure: return "curlybraces"
        case .elixir: return "drop.fill"
        case .lua: return "moon.fill"
        case .julia: return "circle.hexagongrid.fill"
        case .ocaml: return "number"
        case .zig: return "bolt.fill"
        case .nim: return "crown.fill"
        case .crystal: return "diamond.fill"
        case .perl: return "textformat.abc"
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

    /// The toolchain's official brand mark for categories that have one, nil
    /// for the generic buckets (app junk, browsers, downloads...) where no
    /// single logo exists and the SF Symbol above is the honest icon.
    var brandLogo: BrandLogo? {
        switch self {
        case .xcode: return .xcode
        case .android: return .android
        case .go: return .go
        case .node: return .node
        case .flutter: return .flutter
        case .rust: return .rust
        case .python: return .python
        case .ruby: return .ruby
        case .php: return .php
        case .dotnet: return .dotnet
        case .scala: return .scala
        case .haskell: return .haskell
        case .clojure: return .clojure
        case .elixir: return .elixir
        case .lua: return .lua
        case .julia: return .julia
        case .ocaml: return .ocaml
        case .zig: return .zig
        case .nim: return .nim
        case .crystal: return .crystal
        case .perl: return .perl
        case .pods: return .pods
        case .homebrew: return .homebrew
        default: return nil
        }
    }

    /// What `CategoryIcon` should draw for this category: the brand mark when
    /// one exists, the SF Symbol otherwise.
    var iconSource: CategoryIcon.Source {
        if let brandLogo {
            return .brand(brandLogo)
        }
        return .symbol(symbol)
    }

    var tint: Color {
        switch self {
        // The other categories already use up all the semantic colors; apps use black/white adaptive color to stay neutral
        case .apps: return .primary
        case .appJunk: return .primary
        case .projects: return .indigo
        case .xcode: return .blue
        case .simulator: return .purple
        case .android: return .green
        case .go: return .cyan
        case .node: return .mint
        case .flutter: return .teal
        case .rust: return .orange
        case .python: return .yellow
        case .ruby: return .red
        case .php: return .indigo
        case .dotnet: return .purple
        case .scala: return .orange
        case .haskell: return .mint
        case .clojure: return .blue
        case .elixir: return .purple
        case .lua: return .blue
        case .julia: return .green
        case .ocaml: return .orange
        case .zig: return .yellow
        case .nim: return .red
        case .crystal: return .cyan
        case .perl: return .teal
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
        case .appJunk: return 1
        case .projects: return 2
        case .xcode: return 3
        case .simulator: return 4
        case .android: return 5
        case .go: return 6
        case .node: return 7
        case .flutter: return 8
        case .rust: return 9
        case .python: return 10
        case .ruby: return 11
        case .php: return 12
        case .dotnet: return 13
        case .scala: return 14
        case .haskell: return 15
        case .clojure: return 16
        case .elixir: return 17
        case .lua: return 18
        case .julia: return 19
        case .ocaml: return 20
        case .zig: return 21
        case .nim: return 22
        case .crystal: return 23
        case .perl: return 24
        case .pods: return 25
        case .ide: return 26
        case .browser: return 27
        case .language: return 28
        case .downloads: return 29
        case .homebrew: return 30
        case .system: return 31
        case .trash: return 32
        }
    }

    static let ordered: [JunkCategory] = allCases.sorted { $0.sortOrder < $1.sortOrder }

    /// Which cleanup feature this category belongs to. The two audiences never
    /// share a category: toolchain caches are meaningless to a general user,
    /// and browser junk is noise to a developer mid-build. The partition also
    /// guarantees no path is cleaned by both features.
    var scope: CleanupScope {
        switch self {
        case .apps, .projects, .xcode, .simulator, .android, .go, .node, .flutter, .rust, .python, .ruby, .php, .dotnet, .scala, .haskell, .clojure, .elixir, .lua, .julia, .ocaml, .zig, .nim, .crystal, .perl, .pods, .ide, .homebrew:
            return .developer
        case .appJunk, .browser, .language, .downloads, .system, .trash:
            return .general
        }
    }
}
