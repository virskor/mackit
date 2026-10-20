import SwiftUI

/// The welcome page shown when no scan has been run yet.
///
/// Lemon's layout: the illustration owns the top half, the copy sits beneath
/// it, and the whole screen is one call to action. The previous version led
/// with a 52pt icon and a system button — a default SwiftUI stack that reads
/// as scaffolding rather than a product. The hero, copy and button now rise in
/// sequence, and the CTA carries the brand green; the composition itself is
/// `HeroPromptView`, shared with the general module's empty state.
struct WelcomeView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        HeroPromptView(
            title: L10n.tr("welcome.title"),
            message: L10n.tr("welcome.message"),
            actionTitle: L10n.tr("welcome.start"),
            actionImage: "magnifyingglass"
        ) {
            vm.startScan()
        } footer: {
            if !vm.projectRoots.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .foregroundStyle(.secondary)
                    Text(verbatim: L10n.fmt(
                        vm.projectRoots.count == 1
                            ? "welcome.projectRoots.one"
                            : "welcome.projectRoots.other",
                        vm.projectRoots.count
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 18)
            }
        }
        // No separate ⌘R binding: the toolbar is right above the welcome page,
        // and the scan shortcut is provided by the button there; binding it in
        // both places would let the system arbitrarily pick one to perform.
    }
}
