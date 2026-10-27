import AppKit
import Carbon
import Foundation

/// What the system currently lets this process do, permission by permission.
///
/// The app runs without the App Sandbox — it must read `~/Library` and
/// `/Applications` to clean caches — so its reach comes from permissions the
/// user grants in System Settings, one row at a time. A grant or a revoke
/// takes effect the moment it is made and changes what the next scan can see,
/// so this component asks the system every time instead of caching an answer.
///
/// Every probe here is side-effect free: none of them pops a dialog. That is
/// what makes it safe to run on every page appearance — a permission page
/// that asks for consent just to render its own status would be the opposite
/// of helpful. Asking on the user's behalf is a separate, explicit action
/// (`requestAutomation`).
enum PermissionStatus {
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
    /// Whether this process can read third-party apps' launch records — the
    /// capability Full Disk Access actually gates for this app.
    ///
    /// There is no public API that answers "does this app have Full Disk
    /// Access" directly, and the answer must not come from the system's TCC
    /// database: that file is shared by every app on the machine, and reading
    /// it to render Mackit's own status would reach past what a permissions
    /// page is about. The app-scoped signal is the one the uninstall tool
    /// already depends on — the Spotlight index's per-app launch record
    /// (`kMDItemLastUsedDate`, see `AppLastOpened`). Reading a third-party
    /// bundle's record is gated by Full Disk Access, measured on a real
    /// machine: 0 of 44 third-party apps under /Applications resolved a date
    /// without it. So the probe asks about Mackit's own bundle — the one
    /// third-party app that is certainly running right now, and therefore
    /// certainly has a record to read.
    ///
    /// `bundlePath` and `lastOpened` are seams for tests. An installed bundle
    /// is required for the answer to mean anything: the gating the
    /// measurement above was taken against applies to /Applications, and a
    /// build running from DerivedData would read its own record either way
    /// and answer "granted" on a machine that granted nothing. ~/Applications
    /// installs are excluded with them — the gating there is unmeasured, and
    /// "could not tell" beats a guess.
    static func fullDiskAccess(
        bundlePath: String = Bundle.main.bundlePath,
        lastOpened: (String) -> Date? = AppLastOpened.lastOpened
    ) -> PermissionStatus {
        guard bundlePath.hasPrefix("/Applications/") else { return .undetermined }
        return lastOpened(bundlePath) == nil ? .notGranted : .granted
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
