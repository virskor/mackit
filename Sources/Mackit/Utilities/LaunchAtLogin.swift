import Foundation
import Security
import ServiceManagement

/// Launch at login: registers the bundled tray agent (`SMAppService.loginItem`).
///
/// Under the split architecture, what lives in the menu bar is the agent, so the login
/// item points to it rather than the main program: at login only the menu bar icon
/// appears, and the main window does not pop up—the main window is opened by the user
/// clicking the tray. The agent must reside in the main program's
/// `Contents/Library/LoginItems/MackitAgent.app` (assembled by Scripts/build-app.sh);
/// running the executable directly from `.build` will fail registration, which is
/// expected.
///
/// A registration carries a cached launch constraint computed from the agent
/// binary at registration time — a code-directory hash for an ad-hoc-signed
/// build (the default for `Scripts/build-app.sh` without a signing identity),
/// an identifier + team pair for a Developer-ID-signed one. Replacing the
/// binary — a rebuild, an update, a reinstall — can leave that constraint
/// pointing at a hash that no longer exists, and the kernel then kills the
/// agent at every login with "Launch Constraint Violation"; launchd removes
/// the service on the spot, so the menu bar icon never appears and the entry
/// it leaves behind no longer resolves. Registering again is what rebuilds
/// the constraint, which is why `repairIfNeeded` exists and is called at every
/// launch.
enum LaunchAtLogin {
    /// Whether launch at login is currently registered. Manual changes made by the user
    /// in "System Settings › General › Login Items" are reflected here as well.
    static var isEnabled: Bool {
        SMAppService.loginItem(identifier: AppIdentity.agentBundleID).status == .enabled
    }

    static func unregister() async throws {
        try await SMAppService.loginItem(identifier: AppIdentity.agentBundleID).unregister()
    }

    /// The UserDefaults key recording which agent binary the current registration was
    /// built from. The binary's cdhash rather than the version string: the constraint
    /// is computed from the binary, and a rebuild of the same commit (or a re-sign with
    /// a different certificate) changes the hash while leaving the version untouched.
    static let registeredCdHashKey = "loginItemRegisteredCdHash"

    // MARK: - Self-healing registration

    /// The user's launch-at-login choice, as persisted in shared settings.
    ///
    /// The persisted intent is the source of truth, not the system registration: a
    /// registration launchd has given up on reads as "not enabled" even though the
    /// user asked for it, and a toggle that silently flipped itself off would lose the
    /// choice exactly when it needs rebuilding. Settings files written before the
    /// intent was persisted have no key and fall back to the system state, which is
    /// what those versions were reading all along.
    @MainActor
    static func preferredIntent(from values: [String: Any] = SharedStore.loadSettings()) -> Bool {
        values["launchAtLogin"] as? Bool ?? isEnabled
    }

    /// Rebuilds the registration when it is missing or was built from a different
    /// agent binary. Safe to call at every launch — a no-op unless something actually
    /// needs rebuilding.
    ///
    /// Returns whether a rebuild happened; throws when the rebuild itself fails, which
    /// the caller surfaces to the user.
    @MainActor
    @discardableResult
    static func repairIfNeeded(
        preferred: Bool,
        currentCdHash: String? = agentCdHash,
        defaults: UserDefaults = .standard
    ) async throws -> Bool {
        guard preferred, let currentCdHash else { return false }
        let service = SMAppService.loginItem(identifier: AppIdentity.agentBundleID)
        let registeredCdHash = defaults.string(forKey: Self.registeredCdHashKey)
        guard needsRepair(
            status: service.status,
            currentCdHash: currentCdHash,
            registeredCdHash: registeredCdHash
        ) else {
            return false
        }
        // Unregister first: registering an already-registered item is a no-op, so the
        // stale entry has to go before a fresh one can take its place.
        do {
            try await service.unregister()
        } catch {
            // An entry the system has already stopped resolving can refuse to
            // unregister; the register below may still succeed, so this is not fatal.
            MackitLog.ui.info("unregistering the stale login item failed: \(error.localizedDescription, privacy: .public)")
        }
        try service.register()
        defaults.set(currentCdHash, forKey: Self.registeredCdHashKey)
        MackitLog.ui.info("rebuilt the launch-at-login registration for agent cdhash \(currentCdHash, privacy: .public)")
        return true
    }

    /// Forgets which binary the registration was built from, so a later re-register
    /// is not mistaken for one that still matches the current binary.
    static func clearRegistrationRecord(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Self.registeredCdHashKey)
    }

    /// Whether the registration has to be rebuilt from the current binary.
    ///
    /// Pure — status and hashes are parameters, not reads — so every branch is
    /// testable without touching the real login items.
    static func needsRepair(
        status: SMAppService.Status,
        currentCdHash: String?,
        registeredCdHash: String?
    ) -> Bool {
        switch status {
        case .enabled:
            // Registered and enabled — but the constraint was computed from the
            // binary that was current when it was registered, so a replaced binary
            // leaves it failing at every login until it is rebuilt.
            return currentCdHash != registeredCdHash
        case .requiresApproval:
            // The user still has to approve the item in System Settings; rebuilding
            // changes nothing about that, so don't churn the registration.
            return false
        case .notRegistered, .notFound:
            // Nothing usable is registered: launchd removes a service whose launch
            // constraint kept failing, and the leftover entry resolves to no bundle.
            return true
        @unknown default:
            return true
        }
    }

    // MARK: - The value the constraint pins

    /// The embedded agent binary's code-directory hash — the value the login item's
    /// launch constraint pins. Nil when the agent is not embedded (running the
    /// executable straight out of `.build`), in which case there is nothing to
    /// register and nothing to repair.
    static var agentCdHash: String? {
        let agentURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/MackitAgent.app")
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(agentURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let hashes = info[kSecCodeInfoCdHashes as String] as? [Data],
              let hash = hashes.first else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
