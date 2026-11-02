import SwiftUI

/// The privileged-helper install confirmation.
///
/// Opened by the first toggle of a system daemon (and by any toggle
/// while a stale helper is in place): the change the user asked for is
/// held until the helper is installed, and confirming here installs and
/// then applies it. The sheet is explicit about what the helper is —
/// a root process whose entire command set is launchd's system-domain
/// service on/off — because a password prompt for an unexplained
/// background install is exactly the kind of thing a user should
/// refuse.
struct HelperInstallSheet: View {
    @Environment(AppViewModel.self) private var vm

    private var model: LoginItemsModel { vm.loginItems }

    /// Whether the sheet is asking for a first install or a reinstall of
    /// a stale helper — the copy differs, the flow does not.
    private var isUpdate: Bool {
        model.helperState.isInstalled
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                IconBadge(
                    systemImage: "lock.shield.fill",
                    tint: .accentColor,
                    diameter: 56,
                    symbolSize: 24
                )

                VStack(spacing: 5) {
                    Text(verbatim: L10n.tr(
                        isUpdate
                            ? "loginItems.helper.updateTitle"
                            : "loginItems.helper.installTitle"
                    ))
                    .font(.system(size: 17, weight: .bold))

                    Text(verbatim: L10n.tr(
                        isUpdate
                            ? "loginItems.helper.updateSummary"
                            : "loginItems.helper.installSummary"
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 8) {
                point("loginItems.helper.point.root")
                point("loginItems.helper.point.scope")
                point("loginItems.helper.point.password")
                point("loginItems.helper.point.removable")
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Button(L10n.tr("common.cancel")) {
                    model.cancelPendingChange()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)

                // While the install runs (the password dialog is up) the
                // button swaps its label for the progress word and
                // disables: a second click during an elevation would
                // queue a second password prompt.
                ProminentActionButton(
                    title: model.isInstallingHelper
                        ? L10n.tr("loginItems.helper.installing")
                        : L10n.tr(
                            isUpdate
                                ? "loginItems.helper.updateAction"
                                : "loginItems.helper.installAction"
                        )
                ) {
                    model.confirmPendingChange()
                }
                .disabled(model.isInstallingHelper)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// One explanatory line, with the checkmark glyph the sheet's
    /// points share.
    private func point(_ key: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)

            Text(verbatim: L10n.tr(key))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
