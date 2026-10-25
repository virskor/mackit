import Foundation

/// The management actions the Homebrew tool offers — the set the official
/// Homebrew GUIs expose, reached through the same brew subcommands they run.
enum HomebrewAction: Equatable, Sendable {
    /// `brew cleanup --prune=all -s` — prunes old Cellar versions and the
    /// download cache. The same command the `cli.brew-cleanup` scan rule
    /// runs, reached here with a size measurement around it.
    case cleanup
    /// `brew autoremove` — uninstalls formulae nothing depends on any more.
    case autoremove
    /// `brew upgrade` — everything with a new version.
    case upgradeAll
    /// `brew upgrade --formula/--cask <name>` — one package.
    case upgrade(HomebrewPackage.Kind, String)
    /// `brew uninstall --formula/--cask <name>`.
    case uninstall(HomebrewPackage.Kind, String)
    /// `brew services start/stop/restart <name>`.
    case startService(String)
    case stopService(String)
    case restartService(String)

    /// The "working on it" label the page shows while the action runs.
    var runningTitle: String {
        switch self {
        case .cleanup: return L10n.tr("homebrew.running.cleanup")
        case .autoremove: return L10n.tr("homebrew.running.autoremove")
        case .upgradeAll: return L10n.tr("homebrew.running.upgradeAll")
        case .upgrade: return L10n.tr("homebrew.running.upgrade")
        case .uninstall: return L10n.tr("homebrew.running.uninstall")
        case .startService, .stopService, .restartService: return L10n.tr("homebrew.running.service")
        }
    }
}

/// What one finished action produced. `measure` carries the only two numbers
/// brew does not print in a machine-readable place — reclaimed bytes and the
/// autoremoved formula count — and is nil for the rest.
struct HomebrewOutcome: Equatable, Sendable {
    let action: HomebrewAction
    let measure: Int64?
    /// A trimmed diagnostic line when the command failed; nil on success.
    let failure: String?

    var succeeded: Bool { failure == nil }

    /// The result line the page shows. Shared by the notice above the section
    /// content and the status pill, so an action never reports itself two
    /// different ways.
    var message: String {
        guard let failure else {
            switch action {
            case .cleanup:
                if let measure, measure > 0 {
                    return L10n.fmt("homebrew.result.cleaned", Formatters.bytes(measure))
                }
                return L10n.tr("homebrew.result.cleanedNone")
            case .autoremove:
                if let measure, measure > 0 {
                    let key = measure == 1
                        ? "homebrew.result.autoremoved.one"
                        : "homebrew.result.autoremoved.other"
                    return L10n.fmt(key, measure)
                }
                return L10n.tr("homebrew.result.autoremovedNone")
            case .upgradeAll:
                return L10n.tr("homebrew.result.upgradedAll")
            case .upgrade(_, let name):
                return L10n.fmt("homebrew.result.upgraded", name)
            case .uninstall(_, let name):
                return L10n.fmt("homebrew.result.uninstalled", name)
            case .startService(let name):
                return L10n.fmt("homebrew.result.serviceStarted", name)
            case .stopService(let name):
                return L10n.fmt("homebrew.result.serviceStopped", name)
            case .restartService(let name):
                return L10n.fmt("homebrew.result.serviceRestarted", name)
            }
        }
        return L10n.fmt("homebrew.result.failed", failure)
    }
}

/// Runs Homebrew's management actions and measures what they reclaimed.
///
/// Like the inspector, every subprocess goes through an injected `run`
/// closure; the size measurements go through an injected `sizeOf`, so tests
/// can pin reclaimed bytes to fixtures without a real Homebrew. The action
/// itself goes through the injected `stream` closure instead, which reports
/// each output line as brew prints it — the live progress the page shows.
/// `stream` has no default: a half-specified call must fail to compile rather
/// than run a real `brew upgrade`.
enum HomebrewActions {
    /// Runs one action with the production seams — what the model calls.
    static func run(
        _ action: HomebrewAction,
        run: BrewCommand = HomebrewRunner.run,
        stream: BrewStreamCommand,
        sizeOf: @escaping @Sendable (String) -> Int64 = { FileSystem.allocatedSize(ofPath: $0) },
        onLine: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> HomebrewOutcome {
        let timeout: Duration = .seconds(600)
        switch action {
        case .cleanup:
            return await cleanup(run: run, stream: stream, sizeOf: sizeOf, timeout: timeout, onLine: onLine)
        case .autoremove:
            return await autoremove(stream: stream, timeout: timeout, onLine: onLine)
        case .upgradeAll:
            return await plain(action, arguments: ["upgrade"], stream: stream, timeout: timeout, onLine: onLine)
        case .upgrade(let kind, let name):
            return await plain(action, arguments: ["upgrade", kind.commandFlag, name], stream: stream, timeout: timeout, onLine: onLine)
        case .uninstall(let kind, let name):
            return await plain(action, arguments: ["uninstall", kind.commandFlag, name], stream: stream, timeout: timeout, onLine: onLine)
        case .startService(let name):
            return await plain(action, arguments: ["services", "start", name], stream: stream, timeout: timeout, onLine: onLine)
        case .stopService(let name):
            return await plain(action, arguments: ["services", "stop", name], stream: stream, timeout: timeout, onLine: onLine)
        case .restartService(let name):
            return await plain(action, arguments: ["services", "restart", name], stream: stream, timeout: timeout, onLine: onLine)
        }
    }

    /// `brew cleanup --prune=all -s`, measuring cache + Cellar around it.
    ///
    /// The before/after measurement is the honest way to report what was
    /// reclaimed: `brew cleanup`'s own stdout is prose, not a byte count, and
    /// guessing from the download cache alone misses the pruned Cellar
    /// versions, which are usually the bigger half.
    static func cleanup(
        run: BrewCommand = HomebrewRunner.run,
        stream: BrewStreamCommand,
        sizeOf: @escaping @Sendable (String) -> Int64 = { FileSystem.allocatedSize(ofPath: $0) },
        timeout: Duration = .seconds(600),
        onLine: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> HomebrewOutcome {
        guard let cellarPath = await run(["--cellar"], timeout), let cachePath = await run(["--cache"], timeout) else {
            return failure(.cleanup, message: L10n.tr("homebrew.error.brewUnavailable"))
        }
        let before = sizeOf(cellarPath) + sizeOf(cachePath)

        guard await stream(["cleanup", "--prune=all", "-s"], timeout, onLine) != nil else {
            return failure(.cleanup, message: L10n.tr("homebrew.error.cleanupFailed"))
        }

        let reclaimed = max(0, before - (sizeOf(cellarPath) + sizeOf(cachePath)))
        MackitLog.brew.info("brew cleanup reclaimed \(reclaimed, privacy: .public) bytes")
        return HomebrewOutcome(action: .cleanup, measure: reclaimed, failure: nil)
    }

    /// `brew autoremove`. brew prints "==> Autoremoving 3 unneeded formulae:"
    /// when it drops something; the count is parsed when present and the
    /// generic success path covers the rest.
    static func autoremove(
        stream: BrewStreamCommand,
        timeout: Duration = .seconds(600),
        onLine: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async -> HomebrewOutcome {
        guard let output = await stream(["autoremove"], timeout, onLine) else {
            return failure(.autoremove, message: L10n.tr("homebrew.error.autoremoveFailed"))
        }
        let count = parseAutoremovedCount(output)
        MackitLog.brew.info("brew autoremove dropped \(count.map(String.init) ?? "unknown", privacy: .public) formulae")
        return HomebrewOutcome(action: .autoremove, measure: count.map(Int64.init), failure: nil)
    }

    /// The shared shape for every action whose only result is success or a
    /// failure line: upgrade, uninstall, service control.
    private static func plain(
        _ action: HomebrewAction,
        arguments: [String],
        stream: BrewStreamCommand,
        timeout: Duration,
        onLine: @escaping @MainActor @Sendable (String) -> Void
    ) async -> HomebrewOutcome {
        guard await stream(arguments, timeout, onLine) != nil else {
            return failure(action, message: L10n.tr("homebrew.error.actionFailed"))
        }
        return HomebrewOutcome(action: action, measure: nil, failure: nil)
    }

    private static func failure(_ action: HomebrewAction, message: String) -> HomebrewOutcome {
        MackitLog.brew.error("brew action failed: \(String(describing: action), privacy: .public)")
        return HomebrewOutcome(action: action, measure: nil, failure: message)
    }

    /// "==> Autoremoving 3 unneeded formulae:" → 3. Nil when brew removed
    /// nothing or printed an unrecognized shape.
    ///
    /// brew headlines every step with "==> ", which the first field check has
    /// to see past — matching the bare verb only ever matched hand-written
    /// fixtures, never real output.
    static func parseAutoremovedCount(_ output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let words = fields.first == "==>" ? fields.dropFirst() : fields[...]
            if words.first == "Autoremoving", let countField = words.dropFirst().first {
                return Int(String(countField))
            }
        }
        return nil
    }
}
