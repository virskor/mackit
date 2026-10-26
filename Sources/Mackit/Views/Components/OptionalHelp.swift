import SwiftUI

/// `.help(_:)` attached only when there is text: an empty string still pops
/// an empty tooltip, so a button with no tooltip must skip the modifier
/// entirely rather than pass "" through.
extension View {
    func optionalHelp(_ text: String?) -> some View {
        modifier(OptionalHelp(text: text))
    }
}

/// The conditional half of `optionalHelp`: a modifier's opaque body may
/// branch between the helped and unhelped view, an extension returning
/// `some View` may not.
private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}
