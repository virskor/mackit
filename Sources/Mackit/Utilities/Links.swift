import Foundation

/// Fixed product links.
///
/// Literals rather than catalog entries: a URL is not copy that gets
/// translated, and every surface has to hand out the same one.
enum Links {
    /// The product page, used by the About page and the share message.
    ///
    /// Force-unwrapped because the string is a literal this repository owns —
    /// the one form of URL that is known valid without checking at runtime.
    static let website = URL(string: "https://www.mingcui.cn")!
}
