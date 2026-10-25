import Foundation

/// One `brew config` line: "HOMEBREW_PREFIX: /opt/homebrew".
///
/// Values may embed their own mappings ("Homebrew Ruby: 4.0.9 => .../ruby"),
/// so the split is on the first ": " only and the rest is kept verbatim.
struct HomebrewConfigEntry: Equatable, Sendable, Identifiable {
    let key: String
    let value: String

    var id: String { key }
}

/// Reads the environment facts a Homebrew support request starts with:
/// `brew config` for the installation and toolchain, and `brew doctor` for
/// the health check. Both are plain-text commands; the page shows them as-is
/// rather than interpreting them, so a warning the user does not understand
/// is still copy-pasteable into an issue.
enum HomebrewEnvironment {
    /// `brew config`, parsed into key/value entries. Nil when the command
    /// fails.
    static func config(run: BrewCommand = HomebrewRunner.run) async -> [HomebrewConfigEntry]? {
        guard let output = await run(["config"], .seconds(120)) else { return nil }
        return parseConfig(output)
    }

    /// `brew doctor`'s full output, nil when the command fails. A healthy
    /// installation prints its "these warnings are just used to help the
    /// maintainers" preamble and nothing else, which is exactly what the
    /// page should show.
    static func diagnostics(run: BrewCommand = HomebrewRunner.run) async -> String? {
        await run(["doctor"], .seconds(300))
    }

    /// Splits "key: value" lines. The "Last commit: 8 hours ago" and
    /// "Homebrew Ruby: 4.0.9 => ..." forms both survive; a line without the
    /// separator (a wrapped continuation) is skipped rather than guessed at.
    static func parseConfig(_ output: String) -> [HomebrewConfigEntry] {
        output.split(separator: "\n").compactMap { line in
            guard let separator = line.range(of: ": ") else { return nil }
            let key = String(line[line.startIndex..<separator.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[separator.upperBound..<line.endIndex])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { return nil }
            return HomebrewConfigEntry(key: key, value: value)
        }
    }
}
