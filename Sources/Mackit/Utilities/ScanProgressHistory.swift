import Foundation

/// Remembers the directory count each finished disk scan ended on, so the
/// next scan of the same tree can show a real fraction and a remaining-time
/// estimate instead of an indeterminate sweep.
///
/// A traversal's total is unknowable up front — that is why the scanning
/// screen sweeps. But the second scan of a tree visits the same directories
/// (the count only moves when the filesystem does), so the previous count is
/// a sound denominator: dividing the running count by it turns the ring into
/// a percentage and the measured rate into a remaining time.
///
/// Keyed by scan root *and* skip-set signature. The count only holds when
/// this scan enters the same folders the previous one did, and approving a
/// TCC-protected home folder mid-session is exactly what changes that — its
/// whole subtree joins the traversal, so the old count would finish early and
/// strand the ring at 100%. Entries are never trimmed: they are a path, a
/// signature and an integer each, and only trees the user actually scanned
/// ever get one.
struct ScanProgressHistory {
    private let defaults: UserDefaults
    private let key = "diskAnalysis.scanHistory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The directory count a previous scan of `root` with the same skip set
    /// ended on, or nil when this tree was never scanned that way.
    func directoryCount(for root: String, signature: String) -> Int? {
        guard let stored = defaults.dictionary(forKey: key) as? [String: Int] else { return nil }
        let count = stored[Self.entryKey(root, signature)]
        return count.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Records a finished scan's directory count as the denominator for the
    /// next scan of the same tree.
    func record(root: String, signature: String, directories: Int) {
        guard directories > 0 else { return }
        var stored = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        stored[Self.entryKey(root, signature)] = directories
        defaults.set(stored, forKey: key)
    }

    /// The unit separator keeps a root path and a signature from running into
    /// each other inside one flat key.
    private static func entryKey(_ root: String, _ signature: String) -> String {
        root + "\u{1F}" + signature
    }
}
