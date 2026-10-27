import AppKit
import Carbon
import Darwin
import Foundation

/// What the system currently lets this process do, permission by permission.
///
/// The app runs without the App Sandbox — it must read `~/Library` and
/// `/Applications` to clean caches — so its reach comes from permissions the
/// user grants in System Settings, one row at a time. This component asks the
/// system every time instead of caching an answer, so System Settings stays
/// the source of truth; whether a fresh grant needs the app relaunched is the
/// system's call, not something a cached status here could fix.
///
/// Every probe here is side-effect free: none of them pops a dialog. That is
/// what makes it safe to run on every page appearance — a permission page
/// that asks for consent just to render its own status would be the opposite
/// of helpful. Asking on the user's behalf is a separate, explicit action
/// (`requestAutomation`).
enum PermissionStatus: Sendable {
    /// The system has granted it.
    case granted
    /// The system holds an answer this app cannot send events (or read
    /// protected locations) with, so System Settings lists this app and is
    /// where the answer changes.
    case notGranted
    /// The system has never been asked — there is no record for this app and
    /// target yet. This is why the Automation pane does not list the app,
    /// and why the answer can only be created by asking, never by visiting
    /// the pane (see `requestAutomation`).
    case notRequested
    /// The probe could not tell: the automation target is not running, or
    /// this is not an installed bundle. The UI says so rather than guessing
    /// in either direction.
    case undetermined
    /// Not a stored permission at all — the system asks every time it is used
    /// (administrator authorization), so there is nothing to grant up front.
    case onDemand
}

enum AppPermissions {
    /// What opening a protected directory did. "Denied" and "missing" must
    /// stay apart: a path that is not usable says nothing about the
    /// permission, while a folder that exists and refuses is the denial.
    enum DirectoryAccess: Equatable {
        /// Opens for reading: the grant is in place.
        case readable
        /// Exists but refuses: the grant is missing.
        case denied
        /// No usable directory here (absent, a symlink, a non-directory).
        /// It says nothing about the permission.
        case missing
    }

    /// Whether this process can read the locations Full Disk Access alone
    /// unlocks.
    ///
    /// There is no public API that answers "does this app have Full Disk
    /// Access". The previous probe asked the Spotlight index for Mackit's own
    /// last-used date, which cannot tell a missing grant from an index that
    /// is not running: with indexing turned off that lookup is nil whether or
    /// not the grant exists, so the probe reported "not granted" either way.
    /// The permission itself is a filesystem gate, so this probe tests the
    /// gate directly by opening one of the folders TCC hides from every
    /// process without the grant. On macOS 27, without the grant, every
    /// candidate below fails with EPERM while `~/Library/Calendars` and
    /// `~/Library/Reminders` open normally — the gate is the permission, not
    /// the folder's mode. With the grant the same open succeeds.
    ///
    /// The first candidate that exists decides: readable means the grant,
    /// denied means its absence. Candidates the account does not have (Mail
    /// or Messages never set up) are skipped, and when none exists at all the
    /// probe answers "undetermined" rather than guessing. Nothing is read
    /// from the opened directory, and the TCC database is never touched.
    ///
    /// The list stays short on purpose: every path here has been protected by
    /// Full Disk Access since before the deployment floor, so a readable
    /// answer really means the grant. A path whose gating is uncertain could
    /// open without the grant and turn the probe into a false positive; a
    /// narrower list can only produce "undetermined", which the UI already
    /// handles honestly.
    ///
    /// `homeDirectory` and `probe` are seams for tests; the defaults are the
    /// real ones.
    static func fullDiskAccess(
        homeDirectory: String = NSHomeDirectory(),
        probe: (String) -> DirectoryAccess = { probeDirectory(at: $0) }
    ) -> PermissionStatus {
        let candidates = [
            "\(homeDirectory)/Library/Safari",
            "\(homeDirectory)/Library/Mail",
            "\(homeDirectory)/Library/Messages",
            "\(homeDirectory)/Library/Shortcuts",
            "\(homeDirectory)/Library/Containers/com.apple.mail",
        ]
        for path in candidates {
            switch probe(path) {
            case .readable: return .granted
            case .denied: return .notGranted
            case .missing: continue
            }
        }
        return .undetermined
    }

    /// Opens `path` as a directory and closes it again — no listing, no
    /// reading. `open` is the call TCC gates; `EACCES`/`EPERM` is a denial,
    /// and every other failure (an absent path, a symlink, a non-directory)
    /// is a candidate this probe cannot use, so the answer falls towards
    /// "undetermined" instead of a false grant. `O_NOFOLLOW` keeps a symlink
    /// sitting at a protected path from answering for the real directory.
    ///
    /// The answer is classified inside the `withCString` closure, right after
    /// `open`, so no later libc call can overwrite `errno`.
    static func probeDirectory(at path: String) -> DirectoryAccess {
        path.withCString { cPath in
            let descriptor = open(cPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                switch errno {
                case EACCES, EPERM: return .denied
                default: return .missing
                }
            }
            close(descriptor)
            return .readable
        }
    }

    /// Whether this app may send Apple events to `bundleID`'s application
    /// right now, without prompting.
    ///
    /// `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`
    /// is a read-only probe of *this app's own* consent entry for that
    /// target: it never pops the consent dialog, and it never says anything
    /// about any other app's permissions.
    static func automation(_ bundleID: String, askUserIfNeeded: Bool = false) -> PermissionStatus {
        var target = AEAddressDesc()
        let id = bundleID as CFString
        let maxSize = CFStringGetMaximumSizeForEncoding(CFStringGetLength(id) + 1, CFStringBuiltInEncodings.UTF8.rawValue)
        var buffer = [UInt8](repeating: 0, count: maxSize)
        let used = CFStringGetBytes(
            id,
            CFRange(location: 0, length: CFStringGetLength(id)),
            CFStringBuiltInEncodings.UTF8.rawValue,
            0,
            false,
            &buffer,
            maxSize,
            nil
        )
        guard used > 0 else { return .undetermined }
        guard OSStatus(AECreateDesc(typeApplicationBundleID, &buffer, used, &target)) == noErr else { return .undetermined }
        defer { AEDisposeDesc(&target) }
        let answer = AEDeterminePermissionToAutomateTarget(&target, kAECoreSuite, kAEOpenDocuments, askUserIfNeeded)
        return status(ofAutomationStatus: answer)
    }

    /// Maps one `AEDeterminePermissionToAutomateTarget` answer to a status.
    ///
    /// The codes are the ones Apple's `AppleEvents.h` documents for that
    /// function, and the three live answers were verified on a real machine
    /// (macOS 27): `noErr` for a permitted running target,
    /// `errAEEventWouldRequireUserConsent` for a running target this app has
    /// never asked about, and `procNotFound` for a target that is not
    /// running. Everything else — a recorded refusal
    /// (`errAEEventNotPermitted`) first among them — means the system holds
    /// an answer this app cannot send events with, which is the same shape
    /// for the UI as any other refusal: System Settings lists the app, and
    /// the pane is where the answer changes.
    static func status(ofAutomationStatus status: OSStatus) -> PermissionStatus {
        switch status {
        case OSStatus(noErr):
            return .granted
        case OSStatus(procNotFound):
            return .undetermined
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notRequested
        default:
            return .notGranted
        }
    }

    /// Asks the system for this app's consent to automate `bundleID` — the
    /// real request, dialog and all.
    ///
    /// This exists because opening the Automation pane is not enough: macOS
    /// lists an app there only once the app has actually asked, and Mackit's
    /// reveal deliberately never sends an event while unpermitted (see
    /// `RevealInFinder`), so on a machine that has never been asked the
    /// settings jump lands on a list the app is not in. Answering this
    /// request is what puts it there — the dialog is the asking.
    ///
    /// The asking call blocks for as long as the dialog is up; Apple's
    /// header says not to call it on the main thread for exactly that
    /// reason, so it runs detached and the answer comes back on the main
    /// actor. The target must already be running (the header says so, and a
    /// target that is not answers `procNotFound` with no dialog) — the UI
    /// only offers the request for a target it has just seen running.
    static func requestAutomation(_ bundleID: String) async -> PermissionStatus {
        await Task.detached {
            automation(bundleID, askUserIfNeeded: true)
        }.value
    }
}
