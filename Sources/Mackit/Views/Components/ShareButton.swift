import AppKit
import SwiftUI

/// The share capsule in the sidebar footer: a pill beside the brand chip that
/// opens the share dialog.
///
/// The capsule copies the brand chip's shape and fill so the two read as a
/// pair, with only the label telling them apart.
///
/// A sheet rather than a popover: sharing is a decision the user makes on
/// purpose, and a modal dialog says so — it holds the window until the message
/// is copied or the dialog is dismissed, where a popover would vanish on the
/// first stray click and take the confirmation with it.
struct ShareButton: View {
    @State private var showsPanel = false

    var body: some View {
        Button {
            showsPanel = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: L10n.tr("share.button"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsPanel) {
            SharePanel()
        }
    }
}

/// The dialog the share capsule opens: what Mackit is, the message it hands
/// out, and the button that puts that message on the clipboard.
///
/// The message is shown above the button rather than copied blind — the user
/// should be able to see, and edit, exactly what they are about to send, so the
/// text is selectable.
struct SharePanel: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityHidden(true)
                Text(verbatim: L10n.fmt("share.title", "Mackit"))
                    .font(.system(size: 14, weight: .semibold))
            }

            Text(verbatim: L10n.tr("share.intro"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: shareMessage)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

            // Copy leads and Done trails: copying is what the dialog is for,
            // dismissing is how the user leaves once it has happened.
            HStack(spacing: 8) {
                Button(action: copy) {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(verbatim: copied ? L10n.tr("share.copied") : L10n.tr("share.copy"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(copied ? Color.green : Color.accentColor))
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    Text(verbatim: L10n.tr("share.done"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    /// The text the copy button puts on the clipboard.
    ///
    /// The site address arrives through the format argument so the URL has one
    /// home in code rather than one per translation.
    private var shareMessage: String {
        L10n.fmt("share.message", Links.website.absoluteString)
    }

    /// Copies the message and flips the button to its confirmed state. The
    /// state holds until the dialog closes rather than reverting on a timer:
    /// the dialog is modal, so there is nothing to come back to, and a button
    /// that quietly turns blue again while the user reads would undo the only
    /// confirmation they get.
    @MainActor
    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shareMessage, forType: .string)
        copied = true
    }
}
