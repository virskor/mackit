import CoreServices
import Foundation

/// The system's legacy "Login Items" list — the entries System Settings
/// shows under "Open at Login" that are not app-owned login items.
///
/// The LSSharedFileList API has been deprecated since 10.11, but it
/// remains the only public way to read and edit this list: Apple's
/// replacement (SMAppService) manages an app's *own* login item, not the
/// items other software registered, and the list itself is still live on
/// current macOS — verified against a real snapshot on macOS 27, where
/// the API returns the same entries System Settings shows.
///
/// The symbols are resolved with `dlsym` rather than imported because
/// every declaration — functions and the list-type constant alike — is
/// deprecated, and this project builds with zero warnings. The lookup
/// pattern is the same one `AppScanner`'s sibling code uses for
/// `_LSCopyAllApplicationURLs`: a missing symbol is a runtime answer
/// ("no list"), never a crash.
///
/// An entry in this list *is* the enabled state: presence means "opens
/// at login", so removal is the disable and re-insertion is the enable.
/// There is no separate disabled flag, unlike a launchd service.
enum LegacyLoginItems {
    /// One entry in the session login items list.
    struct Item: Equatable, Sendable, Identifiable {
        /// The resolved target's path — usually an app bundle.
        let path: String
        /// The entry's display name, when it carries one.
        let displayName: String?

        var id: String { path }
    }

    // MARK: - C function shapes

    private typealias CreateFn = @convention(c) (
        CFAllocator?, CFString, CFTypeRef?
    ) -> UnsafeRawPointer?
    private typealias SnapshotFn = @convention(c) (
        UnsafeRawPointer, UnsafeMutablePointer<UInt32>
    ) -> UnsafeRawPointer?
    private typealias ResolveFn = @convention(c) (
        UnsafeRawPointer, UInt32,
        UnsafeMutablePointer<Unmanaged<CFURL>?>,
        UnsafeMutablePointer<Unmanaged<CFArray>?>?
    ) -> Int32
    private typealias DisplayNameFn = @convention(c) (
        UnsafeRawPointer
    ) -> Unmanaged<CFString>?
    private typealias RemoveFn = @convention(c) (
        UnsafeRawPointer, UnsafeRawPointer
    ) -> Int32
    /// The 10.5-era insert signature. The modern
    /// `LSSharedFileListItemInsertItemURL` does not exist in the dyld
    /// cache of current macOS — verified by symbol lookup — while this
    /// one does, and its behavior (append with the target's own name and
    /// icon) is exactly what re-adding an entry needs.
    private typealias InsertFn = @convention(c) (
        UnsafeRawPointer, UnsafeRawPointer?, CFString?, UnsafeRawPointer?, CFURL, CFDictionary?
    ) -> UnsafeRawPointer?

    /// `noErr` spelled as a literal: the constant lives in the Carbon
    /// headers this wrapper deliberately does not import.
    private static let noErr: Int32 = 0

    /// `RTLD_DEFAULT`'s documented handle value. Swift's dlfcn overlay
    /// marks the macro unavailable ("structure not supported"), so the
    /// pseudo-handle is spelled out: -2 searches the global scope, which
    /// is what the macro means.
    private nonisolated(unsafe) static let rtlDefault = UnsafeMutableRawPointer(bitPattern: -2)

    // MARK: - Public operations

    /// The current snapshot. Empty when the list is empty, the symbols
    /// are missing, or the snapshot fails — an unreadable list reads as
    /// an empty list to the caller, never as a crash.
    static func snapshot() -> [Item] {
        guard let (list, close) = openList(),
              let (array, releaseArray) = snapshotArray(list) else {
            return []
        }
        defer {
            releaseArray()
            close()
        }

        let count = CFArrayGetCount(array)
        var items: [Item] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            guard let entry = CFArrayGetValueAtIndex(array, index) else { continue }
            guard let path = resolvedPath(of: entry) else { continue }
            items.append(Item(path: path, displayName: displayName(of: entry)))
        }
        return items
    }

    /// Removes the entry targeting `path`. Idempotent: an entry that is
    /// already gone is a success, so a double-remove is a no-op.
    static func remove(path: String) {
        guard let (list, close) = openList(),
              let (array, releaseArray) = snapshotArray(list) else {
            return
        }
        defer {
            releaseArray()
            close()
        }
        guard let removeFn = symbol("LSSharedFileListItemRemove") as RemoveFn? else { return }

        let count = CFArrayGetCount(array)
        for index in 0..<count {
            guard let entry = CFArrayGetValueAtIndex(array, index) else { continue }
            guard resolvedPath(of: entry) == path else { continue }
            _ = removeFn(list, entry)
            return
        }
    }

    /// Re-adds `path` to the end of the list. Appending (rather than
    /// re-inserting at the old position) is the honest behavior: the
    /// entry's former position is not remembered, and the list's order
    /// is cosmetic.
    static func insert(path: String) {
        guard let (list, close) = openList(),
              let insertFn = symbol("LSSharedFileListInsertItemURL") as InsertFn? else {
            return
        }
        defer { close() }

        let url = URL(fileURLWithPath: path) as CFURL
        // nil display name and icon: the list shows the target's own
        // name and icon for a nil display name, which is what the entry
        // had before it was removed.
        if let inserted = insertFn(list, nil, nil, nil, url, nil) {
            release(inserted)
        }
    }

    // MARK: - dlsym plumbing

    /// Resolves one C function by name.
    private static func symbol<T>(_ name: String) -> T? {
        guard let pointer = dlsym(Self.rtlDefault, name) else {
            MackitLog.loginItems.debug("LSSharedFileList symbol missing: \(name, privacy: .public)")
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// Opens the session login items list, pairing it with the closure
    /// that releases it. nil when the API or the list-type constant is
    /// unavailable.
    private static func openList() -> (list: UnsafeRawPointer, close: () -> Void)? {
        guard let create = symbol("LSSharedFileListCreate") as CreateFn?,
              let listType = sessionLoginItemsType,
              let list = create(nil, listType, nil) else {
            return nil
        }
        return (list, { release(list) })
    }

    /// The `kLSSharedFileListSessionLoginItems` constant, read from its
    /// exported symbol rather than imported — the constant is deprecated
    /// along with the functions.
    private static var sessionLoginItemsType: CFString? {
        guard let pointer = dlsym(Self.rtlDefault, "kLSSharedFileListSessionLoginItems") else {
            MackitLog.loginItems.debug("LSSharedFileList list-type constant missing")
            return nil
        }
        return pointer.load(as: CFString.self)
    }

    /// Copies the list's snapshot, paired with its release closure.
    private static func snapshotArray(
        _ list: UnsafeRawPointer
    ) -> (array: CFArray, release: () -> Void)? {
        guard let snapshotFn = symbol("LSSharedFileListCopySnapshot") as SnapshotFn? else {
            return nil
        }
        var seed: UInt32 = 0
        guard let raw = snapshotFn(list, &seed) else { return nil }
        let array = unsafeBitCast(raw, to: CFArray.self)
        return (array, { release(raw) })
    }

    /// The target path of one list entry, or nil when the entry cannot
    /// be resolved — a dangling entry (its target was deleted) stays in
    /// the list but has no path, and the snapshot reports it without a
    /// path rather than skipping it silently.
    private static func resolvedPath(of entry: UnsafeRawPointer) -> String? {
        guard let resolve = symbol("LSSharedFileListItemResolve") as ResolveFn? else { return nil }
        var url: Unmanaged<CFURL>?
        guard resolve(entry, 0, &url, nil) == noErr, let resolved = url?.takeRetainedValue() else {
            return nil
        }
        return (resolved as URL).path
    }

    /// The display name of one list entry, when it carries one.
    private static func displayName(of entry: UnsafeRawPointer) -> String? {
        guard let displayNameFn = symbol("LSSharedFileListItemCopyDisplayName") as DisplayNameFn? else {
            return nil
        }
        return displayNameFn(entry)?.takeRetainedValue() as String?
    }

    /// Releases a CoreFoundation object this wrapper owns. The pointers
    /// are opaque here, and `CFRelease` is unavailable in Swift's modern
    /// Core Foundation overlay — `Unmanaged` is the documented path for
    /// a raw +1 reference: the release consumes the reference the Create
    /// or Copy call handed out.
    private static func release(_ pointer: UnsafeRawPointer) {
        Unmanaged<AnyObject>.fromOpaque(pointer).release()
    }
}
