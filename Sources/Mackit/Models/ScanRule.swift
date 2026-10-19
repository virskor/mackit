import Foundation

/// Target shape of a scan rule.
enum RuleTarget: Sendable, Hashable {
    /// Each child under the directory becomes a separate cleanable item (finest granularity).
    case children(String)
    /// The entire directory becomes a single cleanable item.
    case directory(String)
    /// Wildcard match; every match becomes a cleanable item.
    case glob(String)
}

struct ScanRule: Sendable, Identifiable, Hashable {
    let id: String
    let category: JunkCategory
    let target: RuleTarget
    let risk: RiskLevel

    /// Localization key prefix: `rule.<id>.title` / `rule.<id>.note`. The text lives in
    /// Localizable.xcstrings and is derived from the id to keep the two from drifting apart.
    private var key: String { "rule.\(id)" }

    var title: String { L10n.tr("\(key).title") }
    var note: String { L10n.tr("\(key).note") }

    init(
        id: String,
        category: JunkCategory,
        target: RuleTarget,
        risk: RiskLevel
    ) {
        self.id = id
        self.category = category
        self.target = target
        self.risk = risk
    }

    /// Display name in directory mode takes the child's name; glob mode takes the last two
    /// path components to avoid ambiguity between same-named items.
    func displayName(for url: URL) -> String {
        switch target {
        case .children:
            return url.lastPathComponent
        case .directory:
            return title
        case .glob:
            let parent = url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? url.lastPathComponent : "\(parent)/\(url.lastPathComponent)"
        }
    }
}

/// A command-line cleanup rule that invokes the tool's own cleanup command.
struct CLIRule: Sendable, Identifiable, Hashable {
    let id: String
    let category: JunkCategory
    /// Name of the executable that must exist.
    let executable: String
    let arguments: [String]
    /// The command itself (e.g. `go clean -cache`); not localized.
    let title: String
    let risk: RiskLevel
    /// Directories used to estimate size; purely for display.
    let sizeHints: [String]

    /// Localization key prefix: `rule.<id>.note`; the text lives in Localizable.xcstrings.
    private var key: String { "rule.\(id)" }

    var note: String { L10n.tr("\(key).note") }

    init(
        id: String,
        category: JunkCategory,
        executable: String,
        arguments: [String],
        title: String,
        risk: RiskLevel = .safe,
        sizeHints: [String] = []
    ) {
        self.id = id
        self.category = category
        self.executable = executable
        self.arguments = arguments
        self.title = title
        self.risk = risk
        self.sizeHints = sizeHints
    }
}

/// Scan options.
struct ScanOptions: Sendable, Equatable {
    /// Auto-check tier; none means no auto-checking. See `AutoSelectLevel`.
    var autoSelectRisk: AutoSelectLevel = .none
    /// Custom project directories.
    var projectRoots: [String] = []
    /// Project junk directory names.
    var projectJunkNames: [String] = ProjectJunkNames.defaults
    /// Whether to include command-line cleanup items.
    var includeCLI: Bool = true
    /// Maximum traversal depth per project directory.
    var maxProjectDepth: Int = 8
}

/// Common, safely regenerable build-artifact directory names in projects.
enum ProjectJunkNames {
    static let defaults: [String] = [
        "node_modules",
        ".dart_tool",
        ".gradle",
        "Pods",
        "DerivedData",
        "build",
        "dist",
        "out",
        ".next",
        ".nuxt",
        ".turbo",
        ".parcel-cache",
        ".angular",
        ".svelte-kit",
        ".expo",
        ".vercel",
        "target",
        "cmake-build-debug",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        ".ruff_cache",
        ".tox",
        ".venv",
        "vendor"
    ]

    /// Deleting these directories requires re-downloading or re-configuring, a higher risk than pure build artifacts.
    static let reviewed: Set<String> = ["target", "out", "vendor", ".venv", ".tox", "dist"]
}

/// Common project root directories offered for one-click adding.
enum CommonProjectRoots {
    static let candidates: [String] = [
        "~/Projects",
        "~/Documents/GitHub",
        "~/Documents/GitLab",
        "~/dev",
        "~/code",
        "~/workspace",
        "~/IdeaProjects",
        "~/StudioProjects",
        "~/ReactNativeProjects",
        "~/Desktop"
    ]
}
