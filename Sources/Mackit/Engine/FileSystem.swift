import Darwin
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
    ///
    /// The skip is scoped to the Mac's own trees: simulator device data is
    /// plain files that any process can read — enumerating a device's Caches
    /// works without Full Disk Access and pops no dialog (verified from a
    /// process that lacks FDA) — yet almost every entry under
    /// `Devices/<UDID>/data/Library/Caches` is `com.apple.*` service data
    /// (27 of 27 on one observed device), so an unscoped skip blanked the
    /// simulator device cache rules entirely.
    static let systemDataPrefix = "com.apple."

    /// Where simulator device data trees live. See `systemDataPrefix` for why
    /// the system-data skip does not apply beneath this root.
    static let simulatorDevicesRoot = expand("~/Library/Developer/CoreSimulator/Devices")

    /// Whether the `com.apple.*` system-data skip applies to entries listed
    /// from `directory`. True everywhere except inside simulator device data
    /// trees, whose Library-like layout holds per-simulator service caches
    /// rather than the Mac's TCC-protected system data.
    static func skipsSystemData(under directory: String) -> Bool {
        !(directory + "/").hasPrefix(simulatorDevicesRoot + "/")
    }

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
        // Decode only up to the NUL terminator: the buffer is a fixed PATH_MAX
        // array, not a count-delimited slice. CChar rebinds to UTF-8's code
        // unit — same width, unsigned view of the same bytes.
        let end = buffer.firstIndex(of: 0) ?? buffer.count
        return buffer[..<end].withUnsafeBufferPointer { chars in
            chars.withMemoryRebound(to: UInt8.self) { bytes in
                String(decoding: bytes, as: UTF8.self)
            }
        }
    }

    static func exists(_ path: String) -> Bool {
        manager.fileExists(atPath: expand(path))
    }

    /// Expand `~` into a URL.
    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: expand(path))
    }

    /// One directory entry as `getattrlistbulk` reports it.
    private struct BulkEntry {
        var name: String
        /// The vnode type (VREG / VDIR / VLNK / … — see sys/vnode.h).
        var type: vtype
        /// Bytes allocated to the entry. Regular files only: the kernel
        /// reports nothing here for directories.
        var allocatedSize: Int64
        /// The entry is a mount point — the traversal boundary that keeps a
        /// whole other volume from being counted twice.
        var isMountPoint: Bool
    }

    /// Enumerate one directory's entries, calling `body` once per entry.
    /// Returns false when the directory could not be read at all; the caller
    /// decides whether that means "unreadable" (the measured directory
    /// itself) or "skip" (a directory found mid-traversal).
    ///
    /// One `getattrlistbulk` call returns a whole directory's worth of names
    /// plus attributes — one syscall per directory instead of one `stat` per
    /// entry — which is what makes the traversal cheap: a 112 k-file cache
    /// directory measures in 0.45 s where the Foundation
    /// `contentsOfDirectory` + `resourceValues` route took 5.3 s, and the
    /// listing of a directory with thousands of children appears an order of
    /// magnitude sooner.
    ///
    /// `getattrlistbulk` requires ATTR_CMN_NAME and ATTR_CMN_RETURNED_ATTRS;
    /// the returned mask decides which fields each record actually carries,
    /// so every field is read behind its own flag. The record layout follows
    /// getattrlist(2): the uint32 length, the returned attribute set, then
    /// the requested attributes in bit order, with variable-length data
    /// (the name) addressed by an attrreference relative to the reference
    /// itself. "." and ".." are never returned.
    private static func enumerateBulk(atPath path: String, _ body: (BulkEntry) -> Void) -> Bool {
        let dirfd = open(path, O_RDONLY | O_DIRECTORY)
        guard dirfd >= 0 else { return false }
        defer { close(dirfd) }
        var attrs = attrlist(
            bitmapcount: UInt16(ATTR_BIT_MAP_COUNT),
            reserved: 0,
            commonattr: attrgroup_t(UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_OBJTYPE)),
            volattr: 0,
            dirattr: attrgroup_t(UInt32(ATTR_DIR_MOUNTSTATUS)),
            fileattr: attrgroup_t(UInt32(ATTR_FILE_ALLOCSIZE)),
            forkattr: 0
        )
        // 64 KB holds hundreds of records per call, and a single record is at
        // most a few hundred bytes (a NAME_MAX name plus its attributes), so
        // the buffer can never be too small to hold one entry.
        let capacity = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            let count = getattrlistbulk(dirfd, &attrs, buffer, capacity, UInt64(FSOPT_NOFOLLOW))
            guard count > 0 else { return count == 0 }
            var offset = 0
            for _ in 0..<count {
                let record = buffer.advanced(by: offset)
                let length = record.load(as: UInt32.self)
                // A record that does not fit, or that is too small for the
                // fixed header, would desynchronize the walk — bail out
                // rather than parse garbage.
                guard length >= 24, offset + Int(length) <= capacity else { return false }
                let returned = record.advanced(by: 4).load(as: attribute_set_t.self)
                var field = record.advanced(by: 24)
                var name = ""
                if returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 {
                    let reference = field.load(as: attrreference.self)
                    let data = field.advanced(by: Int(reference.attr_dataoffset))
                    // attr_length counts the trailing NUL.
                    name = String(
                        decoding: UnsafeRawBufferPointer(start: data, count: Int(reference.attr_length)).prefix { $0 != 0 },
                        as: UTF8.self
                    )
                    field = field.advanced(by: 8)
                }
                var type: vtype = VNON
                if returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 {
                    // An unknown value is fine: only VREG and VDIR drive
                    // decisions, everything else falls through to the default.
                    type = vtype(rawValue: field.load(as: UInt32.self))
                    field = field.advanced(by: 4)
                }
                var isMountPoint = false
                if returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS) != 0 {
                    isMountPoint = field.load(as: UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
                    field = field.advanced(by: 4)
                }
                var allocatedSize: Int64 = 0
                if returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0 {
                    // The kernel packs the 8-byte size at a 4-byte-aligned
                    // offset inside the record, so the aligned load would
                    // trap on the misaligned address.
                    allocatedSize = field.loadUnaligned(fromByteOffset: 0, as: off_t.self)
                }
                offset += Int(length)
                if name.isEmpty { continue }
                body(BulkEntry(name: name, type: type, allocatedSize: allocatedSize, isMountPoint: isMountPoint))
            }
        }
    }

    /// A child's path, joined without an intermediate `URL`.
    ///
    /// The disk analysis asks for this once per retained node and once per
    /// directory the counting walk visits; a URL round trip per entry was
    /// measurable next to the readdir that produced it. Kept here rather than
    /// inlined so the two call sites cannot drift on the root case.
    static func joined(_ name: String, in parent: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    /// The last component of an already-joined path.
    ///
    /// The volume root spells "/" and has no last component; it falls back to
    /// the path itself, which is what `URL.lastPathComponent` reports.
    static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = path[path.index(after: slash)...]
        return name.isEmpty ? path : String(name)
    }

    /// One directory entry with the attributes the disk analysis needs, all
    /// read in the same single `getattrlistbulk` pass as the name.
    struct DirectoryEntry: Sendable {
        let name: String
        /// The directory this entry was found in, spelled as the traversal
        /// spelled its own path.
        let parentPath: String
        let isDirectory: Bool
        let isSymbolicLink: Bool
        /// The entry is a mount point — another volume's root. The disk
        /// analysis skips these: their bytes belong to that volume's
        /// accounting, and a startup-disk scan reaches the data volume's
        /// contents through the firmlinks instead.
        let isMountPoint: Bool
        /// Bytes allocated to the entry. Regular files only — the kernel
        /// reports nothing here for directories.
        let allocatedSize: Int64

        /// Full path, computed rather than stored.
        ///
        /// A scan sums every file in the tree but retains only the shallow
        /// ones, so most entries never need a path at all. Building a URL for
        /// each of them was pure allocation, and the string the analyzer
        /// actually wanted was then derived from that URL at a second cost.
        /// Callers that want a URL still get one, at the moment they ask.
        var path: String {
            FileSystem.joined(name, in: parentPath)
        }

        var url: URL {
            URL(fileURLWithPath: parentPath).appendingPathComponent(name)
        }
    }

    /// The direct children of a directory, each with its attributes. Returns
    /// nil when the directory could not be read at all — the caller decides
    /// whether that means "unreadable" (the measured directory itself) or
    /// "skip" (a directory found mid-traversal).
    static func entries(of path: String) -> [DirectoryEntry]? {
        // One URL for the directory instead of one per child. Normalizing here
        // also keeps child paths spelled as before (no trailing slash, no
        // duplicate separators) — path comparisons rely on it.
        let parentPath = url(path).path
        var entries: [DirectoryEntry] = []
        let skipSystemData = skipsSystemData(under: parentPath)
        let readable = enumerateBulk(atPath: parentPath) { entry in
            // com.apple.* system data is TCC-protected; enumerating it pops an authorization dialog, so it is skipped directly
            if skipSystemData && isSystemData(entry.name) { return }
            entries.append(
                DirectoryEntry(
                    name: entry.name,
                    parentPath: parentPath,
                    isDirectory: entry.type == VDIR,
                    isSymbolicLink: entry.type == VLNK,
                    isMountPoint: entry.isMountPoint,
                    allocatedSize: entry.allocatedSize
                )
            )
        }
        if !readable {
            MackitLog.fs.debug("directory not readable, skipped: \(parentPath, privacy: .public)")
        }
        return readable ? entries : nil
    }

    /// The direct children of a directory.
    static func children(of path: String) -> [URL] {
        entries(of: path)?.map(\.url) ?? []
    }

    /// The directories directly inside `path`, as full paths, from a readdir
    /// pass that reads the entry types the filesystem already reports and
    /// fetches no attributes.
    ///
    /// An order of magnitude cheaper than `entries(of:)`: that call's
    /// `getattrlistbulk` reads every entry's attributes, including each file's
    /// allocated size, which is what makes measuring a tree expensive — a full
    /// traversal with it costs about as much as the measurement itself. The
    /// disk analysis counting pass needs only names and types, and it exists
    /// precisely to hand the measurement a denominator cheaply.
    ///
    /// Applies the exclusions the measuring pass applies: `com.apple.*` system
    /// data (TCC-protected), symlinks (a symlinked directory is not one), and
    /// mount points. Returns nil when the directory could not be read at all.
    static func directories(of path: String) -> [String]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        let parentPath = url(path).path
        let skipSystemData = skipsSystemData(under: parentPath)
        var directories: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            if skipSystemData && isSystemData(name) { continue }
            // d_type comes from the directory entry itself on APFS and HFS+.
            // DT_UNKNOWN (some network and FUSE mounts) reports no type, so it
            // is resolved with a stat — rare enough not to matter for the
            // cost, and skipping it instead would undercount directories the
            // measurement visits, driving the fraction to 100% early.
            let type = entry.pointee.d_type
            guard type == Int8(DT_DIR) || type == Int8(DT_UNKNOWN) else { continue }
            // Built only for entries that survive: this walk sees every file in
            // the tree, and a path for each of them would be thrown away.
            let childPath = Self.joined(name, in: parentPath)
            if type == Int8(DT_UNKNOWN), !Self.isDirectory(childPath) { continue }
            if isMountPoint(childPath) { continue }
            directories.append(childPath)
        }
        return directories
    }

    /// Whether `path` is a directory, without following a symlink. Only used
    /// for entries the filesystem reports no type for.
    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Whether `path` is the root of a mounted filesystem — another volume's
    /// mount point. `statfs` reports the mount point of the volume a path
    /// resolves to, so a directory that is itself a mount point is the one
    /// whose path matches. A firmlink such as `/Users` resolves to its volume
    /// and names that volume's mount point instead, which is what keeps a
    /// traversal following firmlinks while skipping actual mounts — the same
    /// distinction the kernel's own per-entry mount flag makes, at one syscall
    /// per directory rather than one attribute-bearing bulk call.
    private static func isMountPoint(_ path: String) -> Bool {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return false }
        return withUnsafePointer(to: &stats.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) {
                String(cString: $0)
            }
        } == path
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
                    // (except inside simulator device trees, which are plain files)
                    let skipSystemData = skipsSystemData(under: parent.path)
                    for name in names where !(skipSystemData && isSystemData(name)) && fnmatch(component, name, 0) == 0 {
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

    /// The allocated size at a path string. The Homebrew manager measures
    /// directories whose paths arrive as text from `brew --cellar` /
    /// `brew --cache`, and every caller was rebuilding the same URL.
    static func allocatedSize(ofPath path: String) -> Int64 {
        allocatedSize(of: URL(fileURLWithPath: path, isDirectory: true))
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
