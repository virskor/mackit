import Foundation

/// One managed Homebrew service, from `brew services info --all --json`.
///
/// The field names and the `status` values ("started", "none", "scheduled",
/// "stopped", "error", "unknown", "other") come from brew's own
/// `FormulaWrapper#to_hash` / `#status_symbol` — verified against the brew
/// 7.x source, since an empty machine cannot produce a sample payload. The
/// last two appear when launchctl answered in a shape brew cannot parse;
/// they are status words like any other, just rare ones.
struct HomebrewService: Identifiable, Equatable, Sendable {
    /// The formula that owns the service.
    let name: String
    /// The launchd/systemd unit name, e.g. "homebrew.mxcl.mysql".
    let serviceName: String?
    /// brew's status word; see the doc comment for the full set.
    let status: String
    let running: Bool
    let pid: Int?
    let user: String?
    /// The plist/unit file path, when registered.
    let file: String?
    /// Whether the service is registered to launch at login (or boot).
    let registered: Bool

    var id: String { name }

    var isRunning: Bool { running || status == "started" }
}

/// Queries the services brew manages for the current user.
enum HomebrewServices {
    /// `brew services info --all --json`. Returns an empty array when no
    /// service is installed (brew prints `[]`), and nil only when the
    /// command itself fails.
    static func list(run: BrewCommand = HomebrewRunner.run) async -> [HomebrewService]? {
        guard let json = await run(["services", "info", "--all", "--json"], .seconds(120)) else {
            return nil
        }
        return parse(json)
    }

    /// Decodes the JSON payload. Defensive by design: a field brew adds or
    /// drops in a future version must not blank the whole list, so every
    /// key is optional and a missing name skips the entry.
    static func parse(_ json: String) -> [HomebrewService] {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([BrewServiceJSON].self, from: data)
        else { return [] }
        return entries.compactMap { entry in
            guard let name = entry.name, !name.isEmpty else { return nil }
            return HomebrewService(
                name: name,
                serviceName: entry.service_name,
                status: entry.status ?? "none",
                running: entry.running ?? false,
                pid: entry.pid,
                user: entry.user,
                file: entry.file,
                registered: entry.registered ?? false
            )
        }
    }
}

/// The JSON shape brew emits; all optional so a future field change degrades
/// one entry instead of the whole response.
private struct BrewServiceJSON: Decodable {
    let name: String?
    let service_name: String?
    let status: String?
    let running: Bool?
    let pid: Int?
    let user: String?
    let file: String?
    let registered: Bool?
}
