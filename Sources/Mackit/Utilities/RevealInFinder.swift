import AppKit
import Foundation

/// Shows a file or folder in Finder the way "Show in Finder" works everywhere
/// else on the Mac: the window comes forward with the item selected.
///
/// A path is never simply handed to `NSWorkspace.open` for the reveal itself:
/// LaunchServices opens a resource with whatever application claims that kind
/// of resource, and for the bundles a disk scan lists that is not Finder. An
/// application bundle is opened by the app itself — "Show in Finder" on
/// Xcode.app would launch Xcode — and a preference pane by System Settings.
/// Verified against LaunchServices on a real system: `urlForApplication(
/// toOpen:)` reports the bundle itself for an `.app`, System Settings for a
/// `.prefPane`, and Finder for a plain folder. Revealing through Finder's own
/// window sidesteps all of it, so the reveal selects first and keeps the
/// LaunchServices question for the fallback alone.
///
/// Selecting is an AppleEvent to Finder, and an app not permitted to automate
/// Finder gets silence rather than an error — the click would read as a
/// no-op. So the reveal asks for consent the first time it needs it, with the
/// dialog any other app's first reveal shows, and a refusal degrades to the
/// permission-free fallback: the enclosing folder opens with nothing selected.
/// The ask happens at most once — the system records the answer, so a recorded
/// refusal goes straight to the fallback rather than asking again on every
/// click.
enum RevealInFinder {
    /// Shows a file in Finder: its enclosing folder, with the file selected —
    /// what "Show in Finder" means everywhere else on the Mac, and what a
    /// user who just found a large file expects when they click its row.
    static func show(file url: URL) {
        reveal(url, fallback: url.deletingLastPathComponent())
    }

    /// Shows a folder in Finder: its enclosing folder, with the folder itself
    /// selected, exactly as a file is revealed. That is also why the
    /// unreadable and skipped folders a scan lists need no special case here:
    /// Finder opens them with its own permissions.
    static func show(folder url: URL) {
        reveal(url, fallback: opensDirectly(url) ? url : url.deletingLastPathComponent())
    }

    /// Finder's bundle id, the automation target the file reveal selects
    /// through.
    static let finderBundleID = "com.apple.finder"

    /// Terminal's bundle id, the automation target "Open in Terminal" sends
    /// its script to (see `AppViewModel.openInTerminal`). Lives beside the
    /// Finder target because the two are the only applications this app
    /// automates, and the permissions page lists both.
    static let terminalBundleID = "com.apple.Terminal"

    /// What a reveal does, given what the system currently lets this app do.
    enum Decision {
        /// Send the reveal event: Finder comes forward with the item selected.
        case select
        /// Ask for consent once — the dialog is the asking — then select if it
        /// is granted and degrade if it is not.
        case requestThenSelect
        /// Open the fallback window with nothing selected: the permission-free
        /// degradation.
        case openWithoutSelecting
    }

    /// Maps the automation probe's answer onto a reveal.
    ///
    /// `notRequested` is the only direction that asks. It means the target is
    /// running — a target that is not reads as `undetermined` — so the request
    /// has a running target to ask about and the dialog is real; once it is
    /// answered the system holds an answer and the next reveal goes straight
    /// to `select` or `openWithoutSelecting`. A recorded refusal never asks
    /// again: a dialog the user already answered, on every click, is worse
    /// than the fallback.
    ///
    /// `undetermined` still sends. The target is not running, the one
    /// direction the probe cannot answer: with consent on record the event
    /// launches Finder and selects, which is what a granted machine whose
    /// Finder happens to be closed should get, and without a record the send
    /// is the same first reveal every other app shows. A dialog declined there
    /// costs one dead click and records a refusal, after which the fallback
    /// takes over.
    static func decision(for status: PermissionStatus) -> Decision {
        switch status {
        case .granted: return .select
        case .notRequested: return .requestThenSelect
        case .notGranted: return .openWithoutSelecting
        case .undetermined: return .select
        // The administrator-authorization answer: an automation target stores
        // its consent, so this cannot occur, and there is nothing to request
        // up front if it ever did.
        case .onDemand: return .openWithoutSelecting
        }
    }

    /// Reveals `url` selected in Finder, falling back to the window `fallback`
    /// names when the system will not let the reveal select.
    private static func reveal(_ url: URL, fallback: URL) {
        switch decision(for: AppPermissions.automation(finderBundleID)) {
        case .select:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .requestThenSelect:
            // The asking call blocks for as long as its dialog is up, so it
            // runs off the reveal's own call stack; the reveal continues on
            // the main actor with the answer.
            Task { @MainActor in
                if await AppPermissions.requestAutomation(finderBundleID) == .granted {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(fallback)
                }
            }
        case .openWithoutSelecting:
            NSWorkspace.shared.open(fallback)
        }
    }

    /// Whether opening `url` itself shows the folder in Finder rather than
    /// handing it to another application. Only the fallback asks this
    /// question; the reveal above never opens the path it was given.
    static func opensDirectly(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isApplicationKey]))?.isApplication == true {
            return false
        }
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == "com.apple.finder"
    }
}
