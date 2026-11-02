import Foundation

/// Everything the app and the privileged helper must agree on: where the
/// helper lives, what it is called on the Mach bus, and what it may be
/// asked to do.
///
/// The two processes share this file through the `MackitHelperKit` library
/// (SwiftPM forbids one source file in two targets). The trust boundary is
/// the helper: it runs as root, so every request it serves is validated
/// here first, and the app validates the same rules client-side to fail
/// fast with a real message instead of a rejected XPC call.
public enum HelperIdentity {
    /// The app's bundle identifier. The install step verifies its source
    /// sits inside a bundle carrying this identifier, so a helper binary
    /// planted at a matching path outside a real app bundle cannot
    /// install itself system-wide.
    public static let appBundleID = "cn.mingcui.mackit"

    /// The XPC Mach service name. The daemon registers it in the system
    /// bootstrap namespace via its LaunchDaemons plist; the app reaches it
    /// with `NSXPCConnection(machServiceName:options: .privileged)`.
    public static let machServiceName = "cn.mingcui.mackit.helper"

    /// The launchd label of the helper daemon — also its plist's Label and
    /// the name of its own service in the system domain.
    public static let daemonLabel = "cn.mingcui.mackit.helper"

    /// Where the installed helper binary lives. `/Library/PrivilegedHelperTools`
    /// is the conventional home for tools installed alongside a privileged
    /// daemon; the directory is created by the install step.
    public static let installedBinaryPath = "/Library/PrivilegedHelperTools/MackitHelper"

    /// The daemon's LaunchDaemons plist, written by the install step and
    /// read back by the app to tell an installed helper from a missing one.
    /// A custom key (`HelperVersion`) records the app version the install
    /// came from, so a stale helper can be told from a current one without
    /// connecting.
    public static let daemonPlistPath = "/Library/LaunchDaemons/cn.mingcui.mackit.helper.plist"

    /// The helper's version key inside its daemon plist. launchd ignores
    /// unknown keys; the app and the helper both read this one. The value
    /// is the app version the install came from, passed on the install
    /// command line — the helper binary itself carries no version, so a
    /// stale install is detected by comparing the plist's record against
    /// the running app's version.
    public static let plistVersionKey = "HelperVersion"

    /// The daemon plist key holding the code-signing requirements every
    /// XPC client must satisfy — an array, because more than one app
    /// install can share one daemon: a release build in /Applications
    /// beside a development build elsewhere each install the helper in
    /// turn, and each appends its own designated requirement when it
    /// does. A single-entry list would make the two installs evict each
    /// other — every toggle in the app that did not install last would
    /// read as an unreachable helper and trigger a reinstall that
    /// evicts the other one. The daemon joins the array with `or` and
    /// enforces the joined requirement.
    ///
    /// A daemon whose plist carries no valid requirement refuses every
    /// connection: an unauthenticated root daemon is the one state this
    /// design must never be in.
    public static let authorizedClientRequirementsKey = "AuthorizedClientRequirements"

    /// The helper's location inside the app bundle. The install step is
    /// launched from exactly here, and the root install refuses any source
    /// path that is not — a helper binary copied anywhere else has no
    /// business installing itself system-wide.
    public static let bundleRelativePath = "Contents/Library/PrivilegedHelperTools/MackitHelper"
}

/// Whether a helper install can be skipped, and what to do when it
/// cannot.
///
/// The decision both sides need: the helper's root install step runs it
/// to choose between reporting "already installed" and doing the work,
/// and the app reads the same shape when it verifies an install's end
/// state. Pure, so the rule is pinned by tests rather than left to a
/// live machine.
public enum HelperInstall {
    public enum Plan: Equatable, Sendable {
        /// The daemon is in place, current and loaded: nothing to do.
        case skip
        /// Install or reinstall is needed.
        case install
    }

    /// The plan for the on-disk state `binaryExists` / `versionStale` /
    /// `daemonLoaded` describe.
    ///
    /// A skip is safe only when the daemon is actually loaded. Files on
    /// disk with a dead daemon is the broken-install state — the
    /// version record matches, so a version-only check reads it as
    /// "already installed" and skips the bootstrap that would bring the
    /// daemon back, leaving every toggle failing with no way out. The
    /// loaded check is what makes the reinstall a repair.
    public static func plan(
        binaryExists: Bool,
        versionStale: Bool,
        daemonLoaded: Bool
    ) -> Plan {
        guard binaryExists, !versionStale, daemonLoaded else { return .install }
        return .skip
    }
}

/// The helper's entire command set.
///
/// Deliberately tiny: the daemon exists to flip launchd's system-domain
/// service state and nothing else. No file deletion, no process signals,
/// no arbitrary command execution — each request names a service by its
/// label and plist, both validated before the helper acts.
@objc(MackitHelperProtocol)
public protocol MackitHelperProtocol {
    /// Enables the system service `label` (recorded in launchd's override
    /// database) and bootstraps its `plistPath` when it is not already
    /// loaded, so the change takes effect without a reboot.
    func enableSystemService(label: String, plistPath: String, withReply reply: @escaping (Bool, String?) -> Void)
    /// Disables the system service `label` and tears it down when loaded.
    func disableSystemService(label: String, withReply reply: @escaping (Bool, String?) -> Void)
    /// Removes the helper itself: bootout, delete the daemon plist and the
    /// installed binary, then exit. The only destructive operation the
    /// helper performs, and it targets exactly its own two files.
    func uninstallHelper(withReply reply: @escaping (Bool, String?) -> Void)
}
