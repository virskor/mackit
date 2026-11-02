import SwiftUI

/// SF Symbols whose presence on the app's floor OS is not guaranteed.
///
/// SF Symbols availability is invisible to the compiler: a symbol
/// introduced in a later SF Symbols release renders blank on an older
/// macOS, and nothing in the build catches it — unlike an API, a symbol
/// name carries no `@available` annotation to check. The check
/// therefore runs against the running OS itself:
/// `NSImage(systemSymbolName:)` (`imageWithSystemSymbolName:`,
/// `API_AVAILABLE(macos(11.0))`, documented nullable) answers nil for a
/// name the system's symbol catalog does not carry — verified live,
/// where a bogus name returns nil and every real symbol returns an
/// image. A symbol the floor lacks degrades to `fallback` instead of
/// vanishing from the interface.
///
/// `fallback` should itself be a symbol the app already ships: the
/// released app's own symbol set is the only availability evidence a
/// development machine can offer for an OS it does not run.
///
/// Use this for any symbol not already in the app's shipped set; a
/// symbol the released version renders on macOS 14 needs no wrapper.
@MainActor
enum VersionedSymbol {
    /// The symbol to render: `name` when the running OS carries it,
    /// `fallback` when it does not.
    static func resolve(_ name: String, fallback: String) -> String {
        if let resolved = cache[name] { return resolved }
        let resolved = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
            ? name
            : fallback
        cache[name] = resolved
        return resolved
    }

    /// One lookup per distinct name per process: the running OS's
    /// symbol catalog is fixed for the process's lifetime, so the
    /// answer cannot change while it runs.
    private static var cache: [String: String] = [:]
}

/// `Image(systemName:)` through the version check, for the call sites
/// that build the image directly rather than through a label.
struct VersionedSymbolImage: View {
    /// The preferred symbol.
    let name: String
    /// The symbol shown when the running OS does not carry `name`.
    var fallback: String

    var body: some View {
        Image(systemName: VersionedSymbol.resolve(name, fallback: fallback))
    }
}
