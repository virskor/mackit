import Darwin
import Foundation

/// Applies one startup item's enabled state.
///
/// Each kind has its own mechanism, and the split is where the
/// privilege boundary lives:
///
/// - user and global agents run in the current user's own `gui/$UID`
///   domain, so their overrides and their load/unload need no
///   privileges at all — `launchctl enable/disable` records the override
///   in the user's database, and `bootstrap`/`bootout` applies it to the
///   running session;
/// - system daemons run in the system domain, which only root may
///   change, so those go through the privileged helper;
/// - legacy login items have no override database — the entry's presence
///   in the list *is* the enabled state, so removing and re-inserting is
///   the whole operation.
///
/// Every sequence was verified against a live launchd on macOS: the
/// enable/disable override lands first (it is what survives a reboot),
/// then the running session is brought in line only when it is not
/// already — a service that is loaded stays loaded when enabled, and a
/// service that is not loaded has nothing to tear down when disabled.
enum LoginItemActions {
    /// Sets `item`'s state. A failure carries a diagnostic naming the
    /// item or the helper's own reason; success carries nothing.
    static func setEnabled(
        _ item: LoginItem,
        enabled: Bool,
        launchctl: LaunchctlRun = { arguments in await LaunchctlRunner.run(arguments) }
    ) async -> HelperOutcome {
        switch item.kind {
        case .userAgent, .globalAgent:
            return await setAgentEnabled(item, enabled: enabled, launchctl: launchctl)
        case .systemDaemon:
            guard let plistPath = item.plistPath else {
                return .failed(L10n.tr("loginItems.action.failed"))
            }
            return await HelperClient.setSystemService(label: item.label, plistPath: plistPath, enabled: enabled)
        case .legacyLoginItem:
            guard let target = item.targetPath else {
                return .failed(L10n.tr("loginItems.action.failed"))
            }
            if enabled {
                LegacyLoginItems.insert(path: target)
            } else {
                LegacyLoginItems.remove(path: target)
            }
            return .success
        }
    }

    /// The user-domain sequence for a launch agent.
    private static func setAgentEnabled(
        _ item: LoginItem,
        enabled: Bool,
        launchctl: LaunchctlRun
    ) async -> HelperOutcome {
        guard let plistPath = item.plistPath else {
            return .failed(L10n.tr("loginItems.action.failed"))
        }
        let label = item.label
        let uid = getuid()

        // The override first: it is the part that persists across
        // reboots, so a failure here means the item would still start at
        // next login even if the session-side change below succeeded.
        let override = enabled ? "enable" : "disable"
        guard await launchctl([override, "gui/\(uid)/\(label)"]) != nil else {
            return .failed(L10n.fmt("loginItems.action.failedLabel", label))
        }
        // The exit status is not the verdict. `launchctl enable/disable`
        // exits zero for any well-formed label — verified live against a
        // label that names no service, which returns exit 0 and records
        // the override anyway — so the recorded state is read back and
        // compared. A missing record, or one that disagrees with the
        // requested state, is the failure the exit status cannot see.
        guard await recordedEnabledState(label: label, uid: uid, launchctl: launchctl) == enabled else {
            return .failed(L10n.fmt("loginItems.action.failedLabel", label))
        }

        // The session-side change only when the state differs: enabling
        // a loaded service is a no-op, and tearing down an unloaded one
        // fails. `print` exits zero exactly when the service is loaded.
        let isLoaded = await launchctl(["print", "gui/\(uid)/\(label)"]) != nil
        if enabled {
            guard !isLoaded else { return .success }
            guard await launchctl(["bootstrap", "gui/\(uid)", plistPath]) != nil else {
                return .failed(L10n.fmt("loginItems.action.failedLabel", label))
            }
        } else {
            guard isLoaded else { return .success }
            guard await launchctl(["bootout", "gui/\(uid)/\(label)"]) != nil else {
                return .failed(L10n.fmt("loginItems.action.failedLabel", label))
            }
        }
        return .success
    }

    /// The label's recorded override state — true when enabled — read
    /// back from launchd's own dump, or nil when the dump carries no
    /// record for the label at all.
    private static func recordedEnabledState(
        label: String,
        uid: uid_t,
        launchctl: LaunchctlRun
    ) async -> Bool? {
        guard let dump = await launchctl(["print-disabled", "gui/\(uid)"]) else { return nil }
        return LoginItemScanner.parseDisabledStates(dump)[label]
    }
}
