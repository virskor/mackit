import Foundation

enum FileSystem {
    /// The thread safety of FileManager.default is guaranteed by Apple's documentation.
    nonisolated(unsafe) static let manager = FileManager.default

    /// The prefix for system-managed data. Since macOS 26+, `com.apple.*`
    /// cache / container / state directories are TCC-protected: recursively
    /// enumerating them pops a system authorization dialog (observed as
    /// "Allow Mackit to access media library in Apple Music"). This is data
    /// maintained by the system itself, which third-party cleaning tools
    /// should not touch anyway, so it is skipped during enumeration.
    static let systemDataPrefix = "com.apple."

    /// Whether this is system-managed data (skipped during enumeration).
    static func isSystemData(_ name: String) -> Bool {
        name.hasPrefix(systemDataPrefix)
    }

    /// Expand `~`.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Canonicalize in the realpath sense: resolve all symlinks in the path.
    ///
    /// Consistent with the return value of `children(of:)` (what
    /// `contentsOfDirectory` returns is the resolved path, `/var` →
    /// `/private/var`), probe paths assembled from strings can only be
    /// compared and deduplicated against it after canonicalization.
    ///
    /// Deliberately not using `NSString.resolvingSymlinksInPath`: on firmlinks
    /// it goes the other way (`/private/var` gets folded back to `/var`), so
    /// the two APIs' canonicalization results differ, and mixing them would
    /// give the same directory two spellings. Returns the path unchanged when
    /// it does not exist.
    static func canonical(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        errno = 0
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    static func exists(_ path: String) -> Bool {
        manager.fileExists(atPath: expand(path))
    }

    /// Expand `~` into a URL.
    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: expand(path))
    }

    /// The direct children of a directory.
    static func children(of path: String) -> [URL] {
        let base = url(path)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        // Unreadable directories (other apps' sandbox containers, TCC-protected
        // areas) are skipped directly: forcing enumeration either fails
        // immediately or pops a system authorization dialog that hangs the scan thread.
        guard manager.isReadableFile(atPath: base.path) else {
            MackitLog.fs.debug("目录不可读，跳过：\(base.path, privacy: .public)")
            return []
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let items = try? manager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) else {
            MackitLog.fs.debug("目录枚举失败，跳过：\(base.path, privacy: .public)")
            return []
        }
        // com.apple.* system data is TCC-protected; enumerating it pops an authorization dialog, so it is skipped directly
        return items.filter { !isSystemData($0.lastPathComponent) }
    }

    /// A minimal wildcard expander that supports matching `*` per path segment.
    /// All patterns in the rules are known constants, so a complete glob
    /// implementation is unnecessary.
    static func expand(pattern: String) -> [URL] {
        let expanded = expand(pattern)
        let components = expanded.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [] }

        var current = [URL(fileURLWithPath: "/", isDirectory: true)]
        for component in components {
            var next: [URL] = []
            if component.contains("*") {
                for parent in current {
                    guard manager.isReadableFile(atPath: parent.path) else { continue }
                    guard let names = try? manager.contentsOfDirectory(atPath: parent.path) else { continue }
                    // com.apple.* system data is TCC-protected: do not expand or descend into it
                    for name in names where !isSystemData(name) && fnmatch(component, name, 0) == 0 {
                        next.append(parent.appendingPathComponent(name))
                    }
                }
            } else {
                for parent in current {
                    next.append(parent.appendingPathComponent(component))
                }
            }
            current = next
            if current.isEmpty { return [] }
        }
        return current.filter { manager.fileExists(atPath: $0.path) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Recursively total the allocated size, not following symlinks.
    static func allocatedSize(of url: URL) -> Int64 {
        // A symlink counts as only the link itself: removeItem also removes only
        // the link when deleting, not the target directory along with it, so
        // counting the size by the target would over-report.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return symbolicLinkSize(of: url)
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return fileSize(of: url)
        }
        return directorySize(of: url)
    }

    /// The size of the symlink itself (lstat semantics, usually only a few dozen bytes).
    private static func symbolicLinkSize(of url: URL) -> Int64 {
        let attributes = try? manager.attributesOfItem(atPath: url.path)
        return Int64((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }

    private static func fileSize(of url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
            if let allocated = values.totalFileAllocatedSize { return Int64(allocated) }
            if let size = values.fileSize { return Int64(size) }
        }
        return 0
    }

    private static func directorySize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }
        let keySet = Set(keys)
        var total: Int64 = 0
        for case let entry as URL in enumerator {
            guard let values = try? entry.resourceValues(forKeys: keySet) else { continue }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            if let allocated = values.totalFileAllocatedSize {
                total += Int64(allocated)
            } else if let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Recursively total the size and return the most recent modification time, getting both size and time in one traversal.
    static func allocatedSizeAndDate(of url: URL) -> (size: Int64, date: Date?) {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            let size = Int64((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
            return (size, attributes?[.modificationDate] as? Date)
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return (0, nil) }
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let keySet = Set(keys)
        var latest: Date?
        var total: Int64 = 0

        func record(_ values: URLResourceValues) {
            if let date = values.contentModificationDate, latest.map({ date > $0 }) ?? true {
                latest = date
            }
            if values.isRegularFile == true {
                if let allocated = values.totalFileAllocatedSize {
                    total += Int64(allocated)
                } else if let size = values.fileSize {
                    total += Int64(size)
                }
            }
        }

        if !isDirectory.boolValue {
            if let values = try? url.resourceValues(forKeys: keySet) { record(values) }
        } else {
            if let values = try? url.resourceValues(forKeys: keySet) { record(values) }
            guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: nil) else {
                return (total, latest)
            }
            for case let entry as URL in enumerator {
                guard let values = try? entry.resourceValues(forKeys: keySet) else { continue }
                if values.isSymbolicLink == true { continue }
                record(values)
            }
        }
        return (total, latest)
    }

    /// Protected paths; the cleaning engine rejects them outright.
    ///
    /// Both the as-is and realpath spellings are compared: on deletion the
    /// file system acts on the resolved real path (`/var` → `/private/var`),
    /// so recognizing only one spelling would let the other bypass it. When
    /// the path does not exist realpath cannot resolve it, but deleting a
    /// nonexistent path is a no-op anyway.
    static func isProtected(_ path: String) -> Bool {
        let expanded = expand(path)
        if isProtectedSpelling(expanded) { return true }
        let resolved = canonical(expanded)
        return resolved != expanded && isProtectedSpelling(resolved)
    }

    private static func isProtectedSpelling(_ rawPath: String) -> Bool {
        var resolved = rawPath
        // Uniformly strip trailing slashes so "/Library/Apple" and "/Library/Apple/" are equivalent
        while resolved.count > 1, resolved.hasSuffix("/") {
            resolved.removeLast()
        }
        if resolved.isEmpty { return true }

        let home = NSHomeDirectory()
        let protected: Set<String> = [
            "/", "/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/private",
            "/Library", "/Library/Apple", "/Applications", home
        ]
        if protected.contains(resolved) { return true }

        // These directories and their subdirectories are all protected. Both
        // firmlink spellings must be listed: removeItem deletes the resolved
        // real path (/var → /private/var), while realpath can only resolve
        // paths that actually exist, so nonexistent paths are compared as-is;
        // therefore both /var/ and /private/var/ prefixes must be blocked.
        let protectedPrefixes = [
            "/System/", "/usr/", "/bin/", "/sbin/", "/etc/", "/private/etc/",
            "/Library/Apple/", "/System/Volumes/Data/System/",
            "/private/var/db/", "/var/db/"
        ]
        for prefix in protectedPrefixes where resolved.hasPrefix(prefix) { return true }

        // The keychain and the root directory of the system volume
        if resolved == "\(home)/Library/Keychains" { return true }
        return false
    }
}

/// Locate executables: only common locations are checked, avoiding a dependency on the login shell's PATH.
enum ToolLocator {
    private static let searchPaths: [String] = [
        "~/Library/pnpm",
        "~/.cargo/bin",
        "~/go/bin",
        "~/.pub-cache/bin",
        "~/.deno/bin",
        "~/.bun/bin",
        "~/.local/bin",
        "~/.rbenv/shims",
        "~/.pyenv/shims",
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    /// The expanded search paths. Reused when `CleanEngine` injects PATH into
    /// the child process, avoiding the divergence of "finding the executable
    /// but its shim cannot find the interpreter".
    static let expandedSearchPaths: [String] = searchPaths.map(FileSystem.expand)

    static func resolve(_ name: String) -> String? {
        if name.contains("/") { return name }
        for directory in expandedSearchPaths {
            let candidate = "\(directory)/\(name)"
            if FileSystem.manager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

/// Volume capacity information, used for the storage bar at the top of the sidebar.
struct VolumeUsage: Sendable, Equatable {
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    static func home() -> VolumeUsage {
        let url = FileSystem.url("~")
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let available = Int64(values?.volumeAvailableCapacity ?? 0)
        return VolumeUsage(total: total, available: available)
    }
}
