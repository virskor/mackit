import SwiftUI

/// The floating action status: a fixed pill in the page's bottom-right corner
/// that shows what brew is doing, and opens the action's log when clicked.
///
/// The pill floats above the section content instead of taking layout space —
/// a `brew upgrade` runs for minutes and the list behind it must stay usable
/// the whole time. It wears the same glass plate as the toast and the
/// clean-progress card, so the window's floating furniture reads as one
/// family, and it stays put in the corner while the content behind scrolls.
struct HomebrewProgressPill: View {
    let progress: HomebrewProgress
    /// Non-nil once the action has finished; the pill switches to the result
    /// state so the log stays reachable for a while afterwards.
    let outcome: HomebrewOutcome?
    var onCopyLog: () -> Void

    @Binding var showsLog: Bool

    var body: some View {
        Button {
            showsLog = true
        } label: {
            plate
        }
        .buttonStyle(.plain)
        .help(L10n.tr("homebrew.progress.openLog"))
        .popover(isPresented: $showsLog, arrowEdge: .bottom) {
            log
        }
    }

    // MARK: - Pill

    private var plate: some View {
        GlassSurface(
            // The result state carries its semantic color the way the toast
            // does; while the action runs the plate stays neutral.
            style: style,
            interactive: true,
            outline: .rounded(cornerRadius: 12),
            fallback: .material(.regularMaterial),
            // Only the result state wears a hairline: a colored edge on a
            // running plate would read as a failure while brew is simply
            // still working.
            fallbackHairline: outcomeHairline,
            fallbackShadow: (color: .black.opacity(0.16), radius: 14, y: 5)
        ) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    stateIcon

                    Text(verbatim: title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    countLabel
                }

                Group {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction)
                    } else {
                        // Indeterminate: brew never says how many paths a
                        // cleanup will remove, and a fake percentage would be
                        // a lie the bar cannot keep.
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .controlSize(.small)

                HStack(spacing: 6) {
                    if let currentStep = progress.currentStep {
                        Text(verbatim: currentStep)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 6)

                    TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                        Text(verbatim: elapsedText(until: context.date))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(width: 268)
        }
    }

    private var style: GlassStyle {
        guard let outcome else { return .regular }
        return .tinted(outcome.succeeded ? .green : .red)
    }

    private var outcomeHairline: (color: Color, width: CGFloat)? {
        guard let outcome else { return nil }
        return ((outcome.succeeded ? Color.green : Color.red).opacity(0.35), 1)
    }

    @ViewBuilder
    private var stateIcon: some View {
        if outcome == nil {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        } else if let outcome, outcome.succeeded {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
        }
    }

    /// The running action's label, or the finished action's result line — the
    /// same one the notice above the section content shows.
    private var title: String {
        outcome?.message ?? progress.action.runningTitle
    }

    @ViewBuilder
    private var countLabel: some View {
        if let total = progress.total, total > 0 {
            Text(verbatim: L10n.fmt("homebrew.progress.count", progress.completed, total))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else if progress.completed > 0 {
            let key = progress.completed == 1
                ? "homebrew.progress.steps.one"
                : "homebrew.progress.steps.other"
            Text(verbatim: L10n.fmt(key, progress.completed))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func elapsedText(until date: Date) -> String {
        // A finished action stops the clock at its finish time.
        let end = progress.finishedAt ?? date
        let seconds = max(0, Int(end.timeIntervalSince(progress.startedAt)))
        return L10n.fmt("homebrew.progress.elapsed", String(format: "%d:%02d", seconds / 60, seconds % 60))
    }

    // MARK: - Log

    private var log: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: L10n.tr("homebrew.progress.logTitle"))
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 8)

                BrandCTAButton(
                    title: L10n.tr("homebrew.progress.copyLog"),
                    systemImage: "doc.on.doc",
                    style: .secondary,
                    compact: true
                ) {
                    Clipboard.copy(progress.log.joined(separator: "\n"))
                    onCopyLog()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(verbatim: progress.log.isEmpty
                        ? L10n.tr("homebrew.progress.logEmpty")
                        : progress.log.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .id("bottom")
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: progress.log.count) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        // Sized for the window's minimum width: the card narrows to about
        // 530pt there, and a wider popover would be clamped by the screen.
        .frame(width: 460, height: 340)
    }
}
