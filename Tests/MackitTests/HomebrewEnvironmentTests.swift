import Foundation
import Testing

@testable import Mackit

/// The `brew config` / `brew doctor` readers.
struct HomebrewEnvironmentTests {
    /// Lines shaped like real `brew config` output, including the "=> "
    /// mapping value and a wrapped continuation line.
    private static let configOutput = """
    HOMEBREW_VERSION: 7.0.10-104-gc5b9f65
    ORIGIN: https://github.com/Homebrew/brew
    HEAD: c5b9f65d0b679d719545df334e8d433a5b6ded3f
    Last commit: 8 hours ago
    Branch: main
    HOMEBREW_PREFIX: /opt/homebrew
    Homebrew Ruby: 4.0.9 => /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.9/bin/ruby
    CPU: octa-core 64-bit arm_blizzard_avalanche
    macOS: 26.1
    this line has no separator and must be skipped
    """

    @Test func parsesConfigEntries() throws {
        let entries = HomebrewEnvironment.parseConfig(Self.configOutput)
        #expect(entries.count == 8, "the separator-less line is skipped, the rest are kept")

        let version = try #require(entries.first { $0.key == "HOMEBREW_VERSION" })
        #expect(version.value == "7.0.10-104-gc5b9f65")

        let commit = try #require(entries.first { $0.key == "Last commit" })
        #expect(commit.value == "8 hours ago")

        // The "=> " mapping is part of the value, not a second split.
        let ruby = try #require(entries.first { $0.key == "Homebrew Ruby" })
        #expect(ruby.value == "4.0.9 => /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.9/bin/ruby")

        let cpu = try #require(entries.first { $0.key == "CPU" })
        #expect(cpu.value == "octa-core 64-bit arm_blizzard_avalanche")
    }

    @Test func configEntriesKeepBrewsOrder() {
        // The page shows them in brew's own order; the split point is a
        // display concern, not a reordering one.
        let entries = HomebrewEnvironment.parseConfig(Self.configOutput)
        #expect(entries.first?.key == "HOMEBREW_VERSION")
        #expect(entries.last?.key == "macOS")
    }

    @Test func emptyConfigYieldsNoEntries() {
        #expect(HomebrewEnvironment.parseConfig("").isEmpty)
        #expect(HomebrewEnvironment.parseConfig("no separators here\nnor here").isEmpty)
    }
}
