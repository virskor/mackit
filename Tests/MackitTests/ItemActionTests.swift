import Foundation
import Testing

@testable import Mackit

/// Helper logic for item actions (right-click menu items).
@MainActor
struct ItemActionTests {
    /// AppleScript string literal escaping.
    ///
    /// The path is embedded in the string of a `do script`; failing to escape
    /// quotes and backslashes produces a script with a syntax error — the user
    /// only sees "Failed to open Terminal" with no hint that special
    /// characters in the path caused it. Backslashes must be escaped first:
    /// the other way around, the backslash just written by quote escaping would
    /// be doubled again.
    @Test func appleScriptEscapingCoversQuotesAndBackslashes() {
        #expect(AppViewModel.appleScriptEscaped("/Users/me/plain") == "/Users/me/plain")
        #expect(AppViewModel.appleScriptEscaped("/tmp/a\"b") == "/tmp/a\\\"b")
        #expect(AppViewModel.appleScriptEscaped("/tmp/a\\b") == "/tmp/a\\\\b")
    }

    /// When both kinds of characters appear together, the result must match
    /// the character-by-character derivation — this guards both "escape both
    /// kinds" and "no double escaping" at once.
    @Test func appleScriptEscapingHandlesMixedSpecialCharacters() {
        let mixed = "/tmp/a\\b\"c\\\\d"
        let expected = mixed.map { character -> String in
            switch character {
            case "\\": return "\\\\"
            case "\"": return "\\\""
            default: return String(character)
            }
        }.joined()

        #expect(AppViewModel.appleScriptEscaped(mixed) == expected)
    }
}
