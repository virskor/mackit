import SwiftUI

/// The overlay while cleaning is in progress.
///
/// A thin wrapper over `CleanProgressOverlay`: the cleanup scan's state lives
/// on the view model, while the uninstall tool's page drives the same overlay
/// from its own model.
struct CleanProgressView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        CleanProgressOverlay(
            progress: vm.cleanProgress,
            cleanedCount: vm.cleanOutcomes.filter(\.succeeded).count,
            currentTitle: vm.cleanCurrentTitle,
            onStop: { vm.cancelClean() }
        )
    }
}
