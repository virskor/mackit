import SwiftUI

/// The result summary after a clean completes, parameterized so both the
/// cleanup scan's page and the uninstall tool's page can present the same
/// result without each binding the view model.
///
/// The vm-bound `CleanResultView` is a thin wrapper over this; the tool page
/// drives it from its own model. The success mark draws itself in on appear —
/// the cleanest moment in the app's flow, and the one place a small
/// celebration earns its keep.
struct CleanResultCard: View {
    /// Bytes actually removed. Only honest when `movedToTrash` is false.
    let reclaimed: Int64
    /// The failed outcomes, listed in full so a failure is never just a count.
    let failures: [CleanOutcome]
    /// Whether anything was recycled rather than deleted: those bytes come
    /// back only once the Trash is emptied, so the summary says "moved out"
    /// instead of claiming them as released.
    let movedToTrash: Bool
    /// Returns to the list the clean ran from.
    let onDone: () -> Void
    /// Starts the scan over. The cleanup scan rescans its rules; the uninstall
    /// tool re-enumerates the installed apps.
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                if failures.isEmpty {
                    SuccessMark(diameter: 72)
                } else {
                    IconBadge(
                        systemImage: "exclamationmark.circle.fill",
                        tint: .orange,
                        diameter: 64,
                        symbolSize: 28
                    )
                }

                VStack(spacing: 6) {
                    Text(verbatim: failures.isEmpty
                        ? L10n.tr("clean.result.done")
                        : L10n.fmt(
                            failures.count == 1
                                ? "clean.result.doneWithFailures.one"
                                : "clean.result.doneWithFailures.other",
                            failures.count
                        ))
                    .font(.system(size: 18, weight: .bold))
                    // Recycling does not free space until the Trash is
                    // emptied, so a clean that moved anything says "moved" instead
                    // of claiming the bytes are already back.
                    Text(verbatim: L10n.fmt(
                        movedToTrash ? "clean.result.movedToTrash" : "clean.result.reclaimed",
                        Formatters.bytes(reclaimed)
                    ))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                if !failures.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: L10n.tr("clean.result.failuresTitle"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(failures) { failure in
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(verbatim: failure.title)
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        Text(verbatim: failure.message)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 130)
                    }
                    .padding(12)
                    .frame(maxWidth: 400)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                HStack(spacing: 10) {
                    BrandCTAButton(title: L10n.tr("common.done"), keyboardShortcut: .defaultAction) {
                        onDone()
                    }

                    Button(L10n.tr("toolbar.rescan")) {
                        onRescan()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
