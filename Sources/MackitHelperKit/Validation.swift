import Foundation

/// Where the system's launchctl actually lives, resolved once per
/// process.
///
/// The binary sits in `/usr/bin` on a standard install, but at least one
/// current macOS layout carries it only in `/bin` — verified on a live
/// machine where the shell's PATH lookup finds it while the hardcoded
/// `/usr/bin/launchctl` path does not exist, which made every
/// launchctl call fail with "file doesn't exist". Both directories are
/// system-owned and not user-writable, so trying them in order is as
/// safe as the single hardcoded path was, and it works on both layouts.
public enum SystemTool {
    /// The resolved launchctl path. Cached: the system layout does not
    /// change under a running process, and every scan makes several
    /// launchctl calls.
    public nonisolated(unsafe) static let launchctlPath: String = {
        for candidate in ["/usr/bin/launchctl", "/bin/launchctl"] {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        // Neither exists: fall back to the traditional path and let the
        // launch failure name it, rather than guessing a third location.
        return "/usr/bin/launchctl"
    }()
}

/// The launchctl commands the helper is allowed to run, as argv arrays.
///
/// Every command the privileged helper executes is one of these cases,
/// built from validated components. There is deliberately no API that
/// takes a caller-supplied command string: the daemon's whole job is the
/// system-domain service on/off switch, so its surface is five fixed
/// argument shapes and nothing else. Execution goes through `Process`
/// with an argv array — no shell is involved, so no quoting or escaping
/// question ever arises.
public enum LaunchctlCommand: Equatable, Sendable {
    /// `launchctl enable system/<label>` — records the service as enabled
    /// in launchd's override database, which is what survives reboots.
    case enableSystem(label: String)
    /// `launchctl disable system/<label>` — the opposite override.
    case disableSystem(label: String)
    /// `launchctl bootstrap system <plistPath>` — loads the service now,
    /// so an enable takes effect without waiting for the next boot.
    case bootstrapSystem(plistPath: String)
    /// `launchctl bootout system/<label>` — tears the service down now.
    case bootoutSystem(label: String)
    /// `launchctl print system/<label>` — the loaded-state probe; exit
    /// status 0 means loaded, anything else means not loaded.
    case printSystem(label: String)

    /// The argv vector, `launchctl` excluded — the runner prepends it.
    public var arguments: [String] {
        switch self {
        case .enableSystem(let label): return ["enable", "system/\(label)"]
        case .disableSystem(let label): return ["disable", "system/\(label)"]
        case .bootstrapSystem(let path): return ["bootstrap", "system", path]
        case .bootoutSystem(let label): return ["bootout", "system/\(label)"]
        case .printSystem(let label): return ["print", "system/\(label)"]
        }
    }
}

/// Request validation for the privileged helper — its trust boundary.
///
/// The helper runs as root and serves any local process that can reach its
/// Mach service, so a malformed or hostile request must never reach
/// `launchctl`. The rules mirror the shape launchd itself guarantees:
/// labels are a restricted character set, and daemon plists live in one
/// directory with one extension. Both sides (app and helper) enforce the
/// same rules — the app so a bad request fails with a real message, the
/// helper because the app is not the only possible caller.
public enum HelperRequest {
    /// launchd labels in the wild: reverse-DNS names, team-id prefixes,
    /// version-bearing names. Characters outside this set have no
    /// legitimate use in a label.
    private static let labelCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
    )

    /// Longest label accepted. Real labels are well under 100 characters;
    /// the ceiling stops a pathological value from reaching the OS at all.
    public static let maxLabelLength = 128

    /// Whether `label` is a well-formed launchd service label.
    public static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= maxLabelLength else { return false }
        return label.rangeOfCharacter(from: labelCharacters.inverted) == nil
    }

    /// Whether `path` is a plausible daemon plist: exactly one file in
    /// `/Library/LaunchDaemons`, with the `.plist` extension. The prefix
    /// check pins the directory (the helper may only manage daemons), the
    /// extension check pins the kind, and the `..` check rejects any
    /// traversal attempt — though as an argv element the path never meets
    /// a shell, this keeps the daemon's file operations honest too.
    public static func isValidSystemPlistPath(_ path: String) -> Bool {
        guard path.hasPrefix("/Library/LaunchDaemons/") else { return false }
        guard path.hasSuffix(".plist") else { return false }
        guard !path.contains("..") else { return false }
        // A bare directory prefix ("/Library/LaunchDaemons/.plist") has no
        // filename; require at least one character between the slash and
        // the extension.
        let fileName = String(path.dropFirst("/Library/LaunchDaemons/".count))
        return fileName.count > ".plist".count
    }

    /// Whether `path` is the bundled helper's location inside an app
    /// bundle. The root install step refuses to copy itself from
    /// anywhere else: a binary at an arbitrary path claiming to be the
    /// helper has no standing to install itself system-wide.
    public static func isBundledHelperPath(_ path: String) -> Bool {
        path.hasSuffix("/" + HelperIdentity.bundleRelativePath)
    }

    /// The commands that enable a system service, or nil when either
    /// component fails validation.
    public static func enableCommands(label: String, plistPath: String) -> [LaunchctlCommand]? {
        guard isValidLabel(label), isValidSystemPlistPath(plistPath) else { return nil }
        return [.enableSystem(label: label), .bootstrapSystem(plistPath: plistPath)]
    }

    /// The commands that disable a system service, or nil when the label
    /// fails validation.
    public static func disableCommands(label: String) -> [LaunchctlCommand]? {
        guard isValidLabel(label) else { return nil }
        return [.disableSystem(label: label), .bootoutSystem(label: label)]
    }

    /// The loaded-state probe for a system service, or nil when the label
    /// fails validation.
    public static func printCommand(label: String) -> LaunchctlCommand? {
        guard isValidLabel(label) else { return nil }
        return .printSystem(label: label)
    }
}

/// Version comparison for the installed-helper check.
///
/// Dot-separated numeric components, compared positionally; a missing
/// component reads as zero, so "1.2" equals "1.2.0". A non-numeric
/// component compares as zero rather than failing the whole comparison —
/// a hand-edited plist should read as stale, not crash the check.
public enum HelperVersion {
    /// Whether the installed helper's recorded version is missing, older
    /// than, or different from `bundled`. Anything that is not exactly
    /// equal counts as stale: the helper's behavior ships with the app,
    /// so a mismatch means one of the two is lying about the other.
    public static func isStale(installed: String?, bundled: String) -> Bool {
        guard let installed else { return true }
        return compare(installed, bundled) != .orderedSame
    }

    /// Positional numeric comparison of two version strings.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
