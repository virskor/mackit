import SwiftUI

/// A one-line terminal command with a copy button — the official Homebrew
/// GUIs' pattern for "here is the command this button runs".
///
/// Showing the command beside the action is the point: a user who does not
/// trust (or does not want) a GUI action can still run it themselves, and a
/// command that failed in the GUI is one they can paste into a terminal to
/// see the full error.
struct TerminalCommandRow: View {
    @Environment(AppViewModel.self) private var vm

    let command: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(verbatim: command)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button {
                vm.copyToClipboard(command)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("homebrew.action.copy"))
            // The label is a bare SF Symbol, so VoiceOver needs the words the
            // tooltip carries.
            .accessibilityLabel(L10n.tr("homebrew.action.copy"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
