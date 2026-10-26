import SwiftUI

/// The result summary after cleaning completes.
///
/// A thin wrapper over `CleanResultCard`: the cleanup scan's state lives on
/// the view model, while the uninstall tool's page drives the same card from
/// its own model.
struct CleanResultView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        CleanResultCard(
            reclaimed: vm.lastReclaimed,
            failures: vm.cleanOutcomes.filter { !$0.succeeded },
            movedToTrash: vm.lastCleanMovedToTrash,
            onDone: { vm.dismissCleanResult() },
            onRescan: {
                vm.dismissCleanResult()
                vm.startScan()
            }
        )
    }
}
