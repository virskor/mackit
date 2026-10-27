import AppKit
import Carbon
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
enum RevealInFinder {
    /// Shows a folder in Finder.
    static func show(folder url: URL) {
        NSWorkspace.shared.open(opensDirectly(url) ? url : url.deletingLastPathComponent())
    }

    /// Shows a file in Finder: its enclosing folder, with the file selected —
    /// what "Show in Finder" means everywhere else on the Mac, and what a
    /// user who just found a large file expects when they click its row.
    ///
    /// Selecting is an AppleEvent to Finder (`activateFileViewerSelecting`),
    /// and an app not permitted to automate Finder gets silence rather than
    /// an error — the click would read as a no-op. Probing first (never
    /// prompting) keeps that outcome impossible: without permission the
    /// reveal degrades to opening the enclosing folder, which needs no
    /// permission at all. A Finder that is not running counts as "cannot
    /// determine" and takes the same fallback — the event would launch it,
    /// and a cold-start consent prompt is a worse first impression than an
    /// unselected reveal.
    static func show(file url: URL) {
        if canAutomate(finderBundleID) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// Finder's bundle id, the automation target the file reveal selects
    /// through.
    static let finderBundleID = "com.apple.finder"

    /// Whether this app may send Apple events to `bundleID`'s application
    /// right now, without prompting.
    ///
    /// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`
    /// is a read-only probe: it never pops the consent dialog, and answers
    /// noErr when the target is running and permitted. The event class and
    /// id passed are immaterial — automation consent is per target
    /// application, not per event — so any pair answers the question. Every
    /// other status (not permitted, would require consent, target not
    /// running, descriptor failure) is a no: the caller has a working
    /// fallback for those.
    static func canAutomate(_ bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let id = bundleID as CFString
        let maxSize = CFStringGetMaximumSizeForEncoding(CFStringGetLength(id) + 1, CFStringBuiltInEncodings.UTF8.rawValue)
        var buffer = [UInt8](repeating: 0, count: maxSize)
        let used = CFStringGetBytes(
            id,
            CFRange(location: 0, length: CFStringGetLength(id)),
            CFStringBuiltInEncodings.UTF8.rawValue,
            0,
            false,
            &buffer,
            maxSize,
            nil
        )
        guard used > 0 else { return false }
        guard OSStatus(AECreateDesc(typeApplicationBundleID, &buffer, used, &target)) == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, kAECoreSuite, kAEOpenDocuments, false) == noErr
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
