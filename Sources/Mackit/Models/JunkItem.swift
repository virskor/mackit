import Foundation

/// A cleanable entity: a directory / file, or a command-line cleanup instruction.
///
/// Derived display text (size string, abbreviated path, search text) is computed once at
/// creation time and stored rather than left to cell render time: with a list of a few
/// thousand entries, calling `ByteCountFormatStyle` / `NSHomeDirectory()` / `lowercased()`
/// for the visible rows on every frame would directly cause stutter while scrolling and
/// checking.
struct JunkItem: Identifiable, Hashable, Sendable {
    /// Composed of the rule id and the path, guaranteeing uniqueness.
    let id: String
    let ruleID: String
    /// Display name, usually the directory name.
    var title: String
    /// Source description, e.g. "Xcode / DerivedData".
    var detail: String
    /// Absolute path; an empty string for command-line cleanup.
    let path: String
    let category: JunkCategory
    var size: Int64 {
        didSet { sizeText = Formatters.bytes(size) }
    }
    /// Display text of the size, updated in sync with size.
    private(set) var sizeText: String
    var modified: Date?
    let risk: RiskLevel
    let isDirectory: Bool
    /// Whether it is a command-line cleanup item.
    let isCommand: Bool
    let command: [String]
    /// Bundle ID of the app an uninstall entry belongs to; nil for non-app entries.
    let bundleID: String?
    /// Kind of an uninstall entry; nil for non-app entries.
    let appKind: AppItemKind?
    /// Display name of the app an entry belongs to, for rows that group their
    /// entries per app (the general module's app-junk sub-rows) and for the
    /// language packs, whose own title is the language code rather than the
    /// app. nil for entries with no owning app.
    let appName: String?
    /// Deleting this entry while its app is running would pull live data out
    /// from under the process: the app's own bundle, and residue that holds
    /// user data (preferences, Application Support, containers, cookies…).
    /// The clean engine refuses those. Regenerable caches and unused language
    /// packs are false here — an app rebuilds a cache on demand, and a
    /// localization the system language never selects is never loaded, so
    /// both are safe to remove at any time.
    let holdsLiveAppData: Bool
    /// Precomputed abbreviated path (home prefix replaced with ~).
    let abbreviatedPath: String
    /// Precomputed lowercased search text, covering name, description, and path.
    let searchBlob: String

    init(
        ruleID: String,
        title: String,
        detail: String,
        path: String,
        category: JunkCategory,
        risk: RiskLevel,
        size: Int64 = 0,
        modified: Date? = nil,
        isDirectory: Bool = true,
        isCommand: Bool = false,
        command: [String] = [],
        bundleID: String? = nil,
        appKind: AppItemKind? = nil,
        appName: String? = nil,
        holdsLiveAppData: Bool = false,
        searchExtra: String? = nil
    ) {
        self.ruleID = ruleID
        self.id = isCommand ? "cli::\(ruleID)" : "\(ruleID)::\(path)"
        self.title = title
        self.detail = detail
        self.path = path
        self.category = category
        self.risk = risk
        self.size = size
        self.sizeText = Formatters.bytes(size)
        self.modified = modified
        self.isDirectory = isDirectory
        self.isCommand = isCommand
        self.command = command
        self.bundleID = bundleID
        self.appKind = appKind
        self.appName = appName
        self.holdsLiveAppData = holdsLiveAppData
        self.abbreviatedPath = Self.abbreviate(path)
        let extra = searchExtra.map { "\n\($0)" } ?? ""
        self.searchBlob = "\(title)\n\(detail)\n\(path)\(extra)".lowercased()
    }

    var displayPath: String {
        path.isEmpty ? command.joined(separator: " ") : path
    }

    var isUnknownSize: Bool { size <= 0 }

    /// Home directory prefix, looked up only once per process.
    ///
    /// `abbreviatedPath` used to be a computed property, calling `NSHomeDirectory()` on
    /// every render of every cell; during fast scrolling of a long list this was visible
    /// overhead.
    private static let homePath = NSHomeDirectory()

    /// Replaces the home prefix with `~`, for the path column in lists.
    ///
    /// The prefix must land on a directory boundary: other users whose names start with
    /// the current username (`/Users/weizhang2`) must not be abbreviated to `~2`.
    static func abbreviate(_ path: String) -> String {
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }
}
