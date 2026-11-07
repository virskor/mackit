import AppKit

/// A capped FIFO cache of file icons, shared by the tool pages that list
/// files.
///
/// `NSWorkspace.icon(forFile:)` is not free, and a list re-renders on every
/// observation change; looking the icon up per row per frame was measurable.
/// The cache is capped because a walk can list thousands of paths and every
/// cached `NSImage` carries its full representation set. Eviction is FIFO:
/// an icon is a couple of syscalls to rebuild, so the policy only has to be
/// cheap.
@MainActor
final class FileIconCache {
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let capacity: Int
    /// The injected lookup; the real one is `NSWorkspace`. A seam so a test
    /// can keep the cache away from the file system.
    private let load: @MainActor @Sendable (String) -> NSImage?

    init(capacity: Int = 128, load: @escaping @MainActor @Sendable (String) -> NSImage?) {
        precondition(capacity > 0, "icon cache capacity must be positive")
        self.capacity = capacity
        self.load = load
    }

    func icon(forPath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = load(path) ?? NSWorkspace.shared.icon(forFile: path)
        if order.count >= capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        order.append(path)
        cache[path] = icon
        return icon
    }
}
