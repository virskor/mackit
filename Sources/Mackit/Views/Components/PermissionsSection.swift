import SwiftUI

/// The permissions report inside Settings → General: which system
/// permissions the app currently holds.
///
/// The app runs without the App Sandbox — it must read `~/Library` and
/// `/Applications` to clean caches — so its reach comes from permissions the
/// user grants in System Settings, one row at a time. Until now each feature
/// that hit a missing permission explained itself in place, which answers
/// "why is this one thing broken" but never "what has this app been allowed
/// overall". This section is that overview: every permission the app uses,
/// whether it is granted right now, what it unlocks, and a button that opens
/// the exact settings row.
///
/// It lives in Settings rather than among the tool pages because it is a
/// report about the app's own standing with the system, not a cleaning
/// action — the same reason the hardware page reports the machine.
///
/// Statuses are probed live, never cached: the section re-probes on
/// appearance and on every return to the app — becoming active again after
/// System Settings (or after answering a consent dialog) is exactly the
/// moment the answer may have changed. Every probe is dialog-free by
/// construction (see `AppPermissions`), so re-probing this often costs
/// nothing the user can feel.
///
/// The automation rows carry a second action, "request": macOS lists an app
/// in the Automation pane only once the app has actually asked, and Mackit's
/// reveal never sends an event while unpermitted (it degrades silently — see
/// `RevealInFinder`), so on a machine that has never been asked the pane is a
/// list the app is not in and the settings jump is a dead end. Answering the
/// request is what puts it there.
struct PermissionsSection: View {
    /// Each surface's live status, keyed by the surface itself. Empty until
    /// the first probe lands; an unknown surface reads as `undetermined`
    /// rather than guessing.
    @State private var statuses: [Surface: PermissionStatus] = [:]

    var body: some View {
        Section {
            Text(verbatim: L10n.tr("settings.permissions.intro"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Surface.allCases) { surface in
                row(surface)
            }
        } header: {
            HStack {
                Label(L10n.tr("settings.permissions.header"), systemImage: "hand.raised.fill")

                Spacer(minLength: 8)

                // A probe is a few directory opens and two permission
                // lookups, so the button never spins — it re-reads the
                // system on the spot.
                Button {
                    probe()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.tr("permissions.refresh.help"))
                .accessibilityLabel(L10n.tr("permissions.refresh"))
            }
        } footer: {
            Text(verbatim: L10n.tr("settings.permissions.footer"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { probe() }
        // Returning from System Settings — or from answering a consent
        // dialog — is the app becoming active again, which is precisely when
        // a grant or a revoke has just happened.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            probe()
        }
    }

    private func row(_ surface: Surface) -> some View {
        let status = statuses[surface] ?? .undetermined

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: surface.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: surface.name)
                    .font(.system(size: 13))

                Text(verbatim: surface.what)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Only the states that need explaining get a hint: a granted
                // row has nothing to add, and the pill already said the rest.
                if let hint = surface.hint(for: status) {
                    Text(verbatim: hint)
                        .font(.system(size: 11))
                        .foregroundStyle(hintTint(for: status))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                PermissionStatusBadge(status: status)

                action(surface, status)
            }
        }
        .padding(.vertical, 4)
    }

    /// The row's action, when it has one.
    ///
    /// A recorded answer (granted or refused) means System Settings lists
    /// this app, so the jump goes straight to the row. `notRequested` means
    /// the opposite — there is no record, so there is nothing in the pane to
    /// toggle — and the only way forward is asking the system, which pops the
    /// consent dialog. A status the probe could not determine offers no
    /// action: the target is not running, and there is no row to visit and
    /// nothing to ask without launching it.
    @ViewBuilder
    private func action(_ surface: Surface, _ status: PermissionStatus) -> some View {
        if let url = surface.settingsURL {
            switch status {
            case .notRequested:
                Button {
                    request(surface)
                } label: {
                    Text(verbatim: L10n.tr("permissions.action.request"))
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .controlSize(.small)
                .help(L10n.tr("permissions.action.request.help"))

            case .granted, .notGranted:
                Button {
                    SystemSettings.open(url)
                } label: {
                    Text(verbatim: L10n.tr("permission.openSettings"))
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .controlSize(.small)
                .help(L10n.tr("permission.openSettings.help"))

            case .undetermined, .onDemand:
                EmptyView()
            }
        }
    }

    /// Asks the system for the row's consent, and shows what it answered.
    ///
    /// The asking itself runs off the main thread (see
    /// `AppPermissions.requestAutomation`), so the section stays responsive
    /// while the dialog is up; the answer it returns is this row's new
    /// status, written straight in. The app becoming active again re-probes
    /// anyway, so a dialog dismissed without the task resuming still lands
    /// on the right status.
    private func request(_ surface: Surface) {
        guard let target = surface.automationTarget else { return }
        Task {
            statuses[surface] = await AppPermissions.requestAutomation(target)
        }
    }

    /// The hint's tint. A refusal is the one state worth an alarm tint; the
    /// rest is explanation, and a column of colored hints would read as
    /// broken. Deliberately not the badge's tint — a granted row's green
    /// capsule next to a gray explanation line would shout the wrong thing.
    private func hintTint(for status: PermissionStatus) -> Color {
        status == .notGranted || status == .notRequested ? .orange : .secondary
    }

    // MARK: - Probing

    /// Re-reads every surface's status from the system. Cheap and
    /// side-effect free — none of the probes can pop a dialog — so it runs on
    /// every appearance and every return to the app without a spinner.
    private func probe() {
        for surface in Surface.allCases {
            statuses[surface] = surface.probe()
        }
    }

    // MARK: - Surfaces

    /// The permissions this app uses, in the order the section lists them.
    ///
    /// Each surface knows what it is called, what it unlocks, where its
    /// settings row lives, and how to ask the system about it — the section
    /// itself stays presentation. A surface with no settings URL
    /// (administrator authorization) is a status the system holds per use,
    /// not per app, so there is nothing to jump to.
    private enum Surface: Identifiable, Hashable {
        case fullDiskAccess
        /// An automation consent: `bundleID` is the application this app asks
        /// to control, `key` names its copy in the catalog.
        case automation(bundleID: String, key: String)
        case administrator

        static var allCases: [Surface] {
            [
                .fullDiskAccess,
                .automation(bundleID: RevealInFinder.finderBundleID, key: "automationFinder"),
                .automation(bundleID: RevealInFinder.terminalBundleID, key: "automationTerminal"),
                .administrator,
            ]
        }

        var id: String {
            switch self {
            case .fullDiskAccess: return "fullDiskAccess"
            case .automation(_, let key): return key
            case .administrator: return "administrator"
            }
        }

        var symbol: String {
            switch self {
            case .fullDiskAccess: return "lock.fill"
            case .automation(RevealInFinder.finderBundleID, _): return "macwindow"
            case .automation: return "terminal"
            case .administrator: return "person.badge.key.fill"
            }
        }

        var name: String {
            L10n.tr("permissions.item.\(id)")
        }

        var what: String {
            L10n.tr("permissions.item.\(id).what")
        }

        var settingsURL: URL? {
            switch self {
            case .fullDiskAccess: return SystemSettings.fullDiskAccess
            // Finder and Terminal share the one Automation row.
            case .automation: return SystemSettings.automation
            case .administrator: return nil
            }
        }

        /// The automation target this row asks about; nil for rows that are
        /// not automation consents — there is nothing to request for them.
        var automationTarget: String? {
            switch self {
            case .automation(let bundleID, _): return bundleID
            case .fullDiskAccess, .administrator: return nil
            }
        }

        func probe() -> PermissionStatus {
            switch self {
            case .fullDiskAccess:
                return AppPermissions.fullDiskAccess()
            case .automation(let bundleID, _):
                return AppPermissions.automation(bundleID)
            case .administrator:
                // The purge authorization is requested per use by the system
                // (see MemoryReleaser); nothing is stored to read back.
                return .onDemand
            }
        }

        /// The line under the row for a status that needs explaining; nil
        /// when the status speaks for itself (granted).
        ///
        /// The undetermined copy is per-surface on purpose: an automation
        /// target that is not running and a probe directory that cannot be
        /// read are different situations, and one shared sentence would
        /// misdescribe at least one of them.
        func hint(for status: PermissionStatus) -> String? {
            switch status {
            case .granted:
                return nil
            case .notGranted:
                return L10n.tr("permissions.hint.notGranted")
            case .notRequested:
                return L10n.tr("permissions.hint.notRequested")
            case .onDemand:
                return L10n.tr("permissions.hint.onDemand")
            case .undetermined:
                switch self {
                case .automation:
                    return L10n.tr("permissions.hint.undetermined.automation")
                case .fullDiskAccess:
                    return L10n.tr("permissions.hint.undetermined.fullDiskAccess")
                case .administrator:
                    // Never undetermined: its status is a constant.
                    return nil
                }
            }
        }
    }
}
