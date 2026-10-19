import SwiftUI

/// Primary action button: shows the checked total size and cleans in one click.
///
/// Placed in the toolbar's `.primaryAction` slot. Do not use `.principal`: that is the
/// window title slot, which frequently does not render in a NavigationSplitView's
/// detail column.
struct CleanSummaryButton: View {
    @Environment(AppViewModel.self) private var vm

    /// The current mode's selection: what this button will clean. The other
    /// mode's checkmarks stay checked but are not this button's business.
    private var scopeSelection: [JunkItem] { vm.scopeSelectedItems }

    private var hasSelection: Bool { !scopeSelection.isEmpty }

    var body: some View {
        Button {
            vm.requestClean()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                if hasSelection {
                    Text(verbatim: L10n.fmt("clean.buttonWithSize", Formatters.bytes(vm.scopeSelectedSize)))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } else {
                    Text(verbatim: L10n.tr("clean.button"))
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(!hasSelection || vm.isBusy)
        .help(hasSelection
            ? L10n.fmt(
                scopeSelection.count == 1
                    ? "clean.helpSelected.one"
                    : "clean.helpSelected.other",
                scopeSelection.count
            )
            : L10n.tr("clean.helpNoSelection"))
    }
}
