import Foundation

/// Live progress for one Homebrew action, and the reader that turns brew's
/// output into it.
///
/// brew reports nothing machine-readable while it works — no percentage, no
/// step count — so the numbers are assembled from the lines it prints: the
/// plan headers that state a total ("==> Autoremoving 3 unneeded formulae:"),
/// the per-package headers ("==> Upgrading codex"), and the per-item removal
/// lines. Every shape recognized below was read off brew 7.x's source and its
/// real output; an unrecognized line is kept in the log and changes nothing.
///
/// The counts are deliberately coarse. A real `brew upgrade` states no total
/// up front (only the dry-run preview does), so the model seeds the plan size
/// from what it already knows — the outdated list — and brew's own headers
/// only ever refine it.
struct HomebrewProgress: Equatable, Sendable {
    let action: HomebrewAction
    /// Packages the action plans to touch. Seeded by the model, or read off
    /// brew's plan header for the actions that decide as they go.
    var total: Int?
    /// Steps brew has reported finished.
    var completed: Int
    /// The package brew is on right now, when its output names one.
    var currentStep: String?
    /// Output lines so far, oldest first.
    var log: [String]
    /// When the action started, for the elapsed readout.
    var startedAt: Date
    /// When the action finished; nil while it runs. Freezes the elapsed
    /// readout at the real duration instead of letting it tick on.
    var finishedAt: Date?

    /// Older lines are dropped once the log is full: a `brew cleanup` on a
    /// neglected Cellar prints one line per removed file, and the newest lines
    /// are the ones someone watching the pill cares about.
    static let logLimit = 400

    init(action: HomebrewAction, total: Int?, startedAt: Date = Date()) {
        self.action = action
        self.total = total
        self.completed = 0
        self.currentStep = nil
        self.log = []
        self.startedAt = startedAt
        self.finishedAt = nil
    }

    /// 0...1 once the total is known; nil while the action is indeterminate
    /// (cleanup removes an unknown number of paths).
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    /// Marks the action finished. Idempotent — the first finish wins, so a
    /// late line arriving after the outcome cannot restart the clock.
    mutating func finish(at date: Date = Date()) {
        if finishedAt == nil { finishedAt = date }
    }

    /// Folds one output line in: the log keeps it, the counters keep what it
    /// says about the plan.
    mutating func append(_ rawLine: String) {
        // curl's download progress rewrites a single line with "\r"; a
        // terminal shows only the final state, and so does the log.
        let line = rawLine.components(separatedBy: "\r").last ?? rawLine
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if log.count >= Self.logLimit { log.removeFirst() }
        log.append(text)

        if total == nil, let planned = Self.plannedCount(text) {
            total = planned
            return
        }
        if let name = Self.upgradedPackage(text) {
            completed += 1
            currentStep = name
            return
        }
        if let name = Self.removedItem(text) {
            completed += 1
            currentStep = name
            return
        }
        // `brew cleanup`'s per-path line: counted, not named — the path is a
        // file deep inside a keg, and its components say nothing to a user.
        if text.hasPrefix("Removing: ") {
            completed += 1
        }
    }

    // MARK: - brew's line shapes

    /// The totals brew states up front: "==> Autoremoving 3 unneeded
    /// formulae:", the dry-run preview "==> Would upgrade 10 outdated
    /// packages", and the (preview-only) "==> Upgrading 10 outdated packages".
    static func plannedCount(_ line: String) -> Int? {
        guard line.hasPrefix("==> ") else { return nil }
        let words = line.dropFirst(4).split(separator: " ")
        guard let verb = words.first else { return nil }
        switch verb {
        case "Autoremoving":
            return words.count > 1 ? Int(String(words[1])) : nil
        case "Would":
            // "Would upgrade 10 outdated packages" — the count trails the
            // verb and its object.
            return words.count > 2 ? Int(String(words[2])) : nil
        case "Upgrading":
            // A leading number is the plan header; a name is a package step.
            guard words.count > 1, let count = Int(String(words[1])) else { return nil }
            return count
        default:
            return nil
        }
    }

    /// "==> Upgrading codex" → "codex". Two look-alikes are deliberately not
    /// steps: "==> Upgrading gh dependency: openssl (3.0->4.0)" (a pulled-in
    /// dependency, which would inflate the plan) and the past-tense summary
    /// "==> Upgraded 10 outdated packages" (the end of the run).
    static func upgradedPackage(_ line: String) -> String? {
        guard let body = headlineBody(line, verb: "Upgrading") else { return nil }
        guard !body.contains(" dependency: ") else { return nil }
        guard let name = body.split(separator: " ").first.map(String.init) else { return nil }
        return Int(name) == nil ? name : nil
    }

    /// The item a removal line names: "==> Uninstalling Cask codex" →
    /// "codex", and "Uninstalling /opt/homebrew/Cellar/gh/2.102.0... (abv)" →
    /// "gh". nil for lines that name no item.
    static func removedItem(_ line: String) -> String? {
        if let body = headlineBody(line, verb: "Uninstalling"), body.hasPrefix("Cask ") {
            return String(body.dropFirst("Cask ".count))
        }
        guard line.hasPrefix("Uninstalling ") else { return nil }
        let named = line.dropFirst("Uninstalling ".count)
        let subject = named.split(separator: "...", maxSplits: 1).first.map(String.init) ?? ""
        guard !subject.isEmpty else { return nil }
        // A keg path (".../Cellar/gh/2.102.0") names its formula one component
        // up; a bare token is the name itself.
        guard subject.contains("/") else { return subject }
        let components = subject.split(separator: "/")
        guard components.count >= 2 else { return subject }
        return String(components[components.count - 2])
    }

    /// The text after a "==> <verb> " headline; nil when the line is not that
    /// headline. Every step brew prints mid-run is a headline.
    private static func headlineBody(_ line: String, verb: String) -> String? {
        guard line.hasPrefix("==> ") else { return nil }
        let body = line.dropFirst(4)
        guard body.hasPrefix(verb + " ") else { return nil }
        return String(body.dropFirst(verb.count + 1))
    }
}
