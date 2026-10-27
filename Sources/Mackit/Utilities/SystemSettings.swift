import AppKit
import Foundation

/// Opens System Settings at the Full Disk Access row.
///
/// `x-apple.systempreferences:` is the URL scheme System Settings registers;
/// the part before `?` selects the pane, the part after it the row inside the
/// pane. Every permission-gated feature in this app (the disk analysis scan,
/// the large-file walk's unreadable folders) sends the user to the same row,
/// so the link lives here once instead of being spelled out at each call
/// site — the same reason `Links` owns the website URL.
///
/// A malformed pane id or anchor does not error: System Settings simply opens
/// somewhere else, and the button reads as a no-op. `SystemSettingsTests`
/// pins the parts of the URL against exactly that failure.
enum SystemSettings {
    /// The Full Disk Access row of the Privacy & Security pane.
    ///
    /// Force-unwrapped because the string is a literal this repository owns —
    /// the one form of URL that is known valid without checking at runtime.
    static let fullDiskAccess = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    /// The Automation row of the Privacy & Security pane, where the per-app
    /// Apple events consents live — Finder for "Show in Finder", Terminal for
    /// "Open in Terminal". Both targets share the one row, so the permissions
    /// page sends either permission to the same place.
    static let automation = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    )!

    /// Opens the Full Disk Access pane, so a permission hint can take the
    /// user straight to the row instead of describing the click path.
    static func openFullDiskAccess() {
        open(fullDiskAccess)
    }

    /// Opens one of the pane URLs above. Shared so a caller that holds a URL
    /// does not re-spell the workspace call.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
