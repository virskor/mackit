import SwiftUI

/// The welcome page shown when no scan has been run yet.
struct WelcomeView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 20) {
                // Brand image (blue double star); falls back to an SF Symbol
                // when the resource is missing.
                if let brandIcon = BrandIcon.image {
                    Image(nsImage: brandIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 52, height: 52)
                } else {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(spacing: 8) {
                    Text(L10n.tr("welcome.title"))
                        .font(.system(size: 22, weight: .bold))
                    Text(verbatim: L10n.tr("welcome.message"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                Button {
                    vm.startScan()
                } label: {
                    Label(L10n.tr("welcome.start"), systemImage: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // No separate ⌘R binding: the toolbar is right above the
                // welcome page, and the scan shortcut is provided by the button
                // there; binding it in both places would let the system
                // arbitrarily pick one to perform.

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
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
