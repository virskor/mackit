import Foundation

/// When an installed app was last opened, read from the Spotlight index's
/// per-app usage record (`kMDItemLastUsedDate`).
///
/// There is no non-gated public API for app launch times; this is the record
/// the system itself maintains, and its reach was verified on macOS 27
/// before this was written: system apps carry a real date for every launch
/// (Notes.app, App Store.app, …), while reading the metadata for
/// third-party bundles under `/Applications` is gated by Full Disk Access —
/// without it the lookup resolves nothing and returns nil for every app,
/// including ones that were certainly launched (measured: 0 of 47
/// third-party apps, Xcode among them, against 13 of 64 system apps).
///
/// Because "no record" and "unreadable index" look identical from here, the
/// caller must treat *no dates at all* as unreadable rather than as "never
/// launched" — see `AppUninstallModel.lastOpenedUnreadable`.
enum AppLastOpened {
    /// When the app bundle at `path` was last opened, or nil when the
    /// system holds no readable record for it.
    static func lastOpened(at path: String) -> Date? {
        guard !path.isEmpty else { return nil }
        // Synchronous and safe to call off the main thread: it reads the
        // metadata server's cached entry, no query or run loop involved.
        let item = NSMetadataItem(url: URL(fileURLWithPath: path))
        return item?.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
    }
}
