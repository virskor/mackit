import AppKit

/// Puts text on the general pasteboard.
///
/// The Homebrew manager's command rows ("brew upgrade --formula brotli")
/// are meant to be copied into a terminal, and `AppViewModel.copyPath` /
/// `ShareButton` each had their own two-line pasteboard dance — this is that
/// dance, once.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
