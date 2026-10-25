import AppKit

/// Puts text on the general pasteboard.
///
/// The Homebrew manager's command rows ("brew upgrade --formula brotli")
/// are meant to be copied into a terminal, and `ShareButton` had its own
/// two-line pasteboard dance — this is that dance, once. A copy that owes the
/// user a confirmation goes through `AppViewModel.copyToClipboard`, which
/// wraps this with the toast.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
