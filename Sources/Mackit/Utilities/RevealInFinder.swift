import AppKit
import Foundation

/// Shows a file or folder in Finder.
///
/// A path is never simply handed to `NSWorkspace.open`: LaunchServices opens
/// a resource with whatever application claims that kind of resource, and for
/// the bundles a disk scan lists that is not Finder. An application bundle is
/// opened by the app itself — "Show in Finder" on Xcode.app would launch
/// Xcode — and a preference pane by System Settings. Verified against
/// LaunchServices on a real system: `urlForApplication(toOpen:)` reports the
/// bundle itself for an `.app`, System Settings for a `.prefPane`, and Finder
/// for a plain folder. So a folder is opened directly only when Finder would
/// open it; anything else is revealed through its enclosing folder — the
/// window the user asked for, without an app starting behind it. An
/// application bundle is refused outright, whatever the query says, because
/// that answer is LaunchServices' and not ours.
///
/// Deliberately not `activateFileViewerSelecting`, which reveals *and*
/// selects: that is an AppleEvent to Finder, and an app the user has not
/// authorized to automate Finder — an ad-hoc build, or a declined prompt —
/// gets silence rather than an error, so the click reads as a no-op.
enum RevealInFinder {
    /// Shows a folder in Finder.
    static func show(folder url: URL) {
        NSWorkspace.shared.open(opensDirectly(url) ? url : url.deletingLastPathComponent())
    }

    /// Shows a file in Finder: its enclosing folder. The file itself is never
    /// opened — that would hand it to its default application.
    static func show(file url: URL) {
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }

    /// Whether opening `url` itself shows the folder in Finder rather than
    /// handing it to another application.
    static func opensDirectly(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true {
            return false
        }
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == "com.apple.finder"
    }
}
