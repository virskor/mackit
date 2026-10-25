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
}

/// Runs Homebrew's management actions and measures what they reclaimed.
///
/// Like the inspector, every subprocess goes through an injected `run`
/// closure; the size measurements go through an injected `sizeOf`, so tests
/// can pin reclaimed bytes to fixtures without a real Homebrew.
enum HomebrewActions {
    /// Runs one action with the production seams — what the model calls.
    static func run(
        _ action: HomebrewAction,
        run: BrewCommand = HomebrewRunner.run,
        sizeOf: @escaping @Sendable (String) -> Int64 = { FileSystem.allocatedSize(ofPath: $0) }
    ) async -> HomebrewOutcome {
        let timeout: Duration = .seconds(600)
        switch action {
        case .cleanup:
            return await cleanup(run: run, sizeOf: sizeOf, timeout: timeout)
        case .autoremove:
            return await autoremove(run: run, timeout: timeout)
        case .upgradeAll:
            return await plain(action, arguments: ["upgrade"], run: run, timeout: timeout)
        case .upgrade(let kind, let name):
            return await plain(action, arguments: ["upgrade", kind.commandFlag, name], run: run, timeout: timeout)
        case .uninstall(let kind, let name):
            return await plain(action, arguments: ["uninstall", kind.commandFlag, name], run: run, timeout: timeout)
        case .startService(let name):
            return await plain(action, arguments: ["services", "start", name], run: run, timeout: timeout)
        case .stopService(let name):
            return await plain(action, arguments: ["services", "stop", name], run: run, timeout: timeout)
        case .restartService(let name):
            return await plain(action, arguments: ["services", "restart", name], run: run, timeout: timeout)
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
        sizeOf: @escaping @Sendable (String) -> Int64 = { FileSystem.allocatedSize(ofPath: $0) },
        timeout: Duration = .seconds(600)
    ) async -> HomebrewOutcome {
        guard let cellarPath = await run(["--cellar"], timeout), let cachePath = await run(["--cache"], timeout) else {
            return failure(.cleanup, message: L10n.tr("homebrew.error.brewUnavailable"))
        }
        let before = sizeOf(cellarPath) + sizeOf(cachePath)

        guard await run(["cleanup", "--prune=all", "-s"], timeout) != nil else {
            return failure(.cleanup, message: L10n.tr("homebrew.error.cleanupFailed"))
        }

        let reclaimed = max(0, before - (sizeOf(cellarPath) + sizeOf(cachePath)))
        MackitLog.brew.info("brew cleanup reclaimed \(reclaimed, privacy: .public) bytes")
        return HomebrewOutcome(action: .cleanup, measure: reclaimed, failure: nil)
    }

    /// `brew autoremove`. brew prints "Autoremoving 3 formulae: a, b, c" when
    /// it drops something; the count is parsed when present and the generic
    /// success path covers the rest.
    static func autoremove(
        run: BrewCommand = HomebrewRunner.run,
        timeout: Duration = .seconds(600)
    ) async -> HomebrewOutcome {
        guard let output = await run(["autoremove"], timeout) else {
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
        run: BrewCommand,
        timeout: Duration
    ) async -> HomebrewOutcome {
        guard await run(arguments, timeout) != nil else {
            return failure(action, message: L10n.tr("homebrew.error.actionFailed"))
        }
        return HomebrewOutcome(action: action, measure: nil, failure: nil)
    }

    private static func failure(_ action: HomebrewAction, message: String) -> HomebrewOutcome {
        MackitLog.brew.error("brew action failed: \(String(describing: action), privacy: .public)")
        return HomebrewOutcome(action: action, measure: nil, failure: message)
    }

    /// "Autoremoving 3 formulae: a, b, c" → 3. Nil when brew removed nothing
    /// or printed an unrecognized shape.
    static func parseAutoremovedCount(_ output: String) -> Int? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.first == "Autoremoving", let countField = fields.dropFirst().first {
                return Int(countField)
            }
        }
        return nil
    }
}
