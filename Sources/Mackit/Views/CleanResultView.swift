import SwiftUI

/// The result summary after cleaning completes.
///
/// The success mark draws itself in on appear — the cleanest moment in the
/// app's flow, and the one place a small celebration earns its keep.
struct CleanResultView: View {
    @Environment(AppViewModel.self) private var vm

    private var failures: [CleanOutcome] { vm.cleanOutcomes.filter { !$0.succeeded } }

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
                    Text(verbatim: L10n.fmt("clean.result.reclaimed", Formatters.bytes(vm.lastReclaimed)))
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
                        vm.dismissCleanResult()
                    }

                    Button(L10n.tr("toolbar.rescan")) {
                        vm.dismissCleanResult()
                        vm.startScan()
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
