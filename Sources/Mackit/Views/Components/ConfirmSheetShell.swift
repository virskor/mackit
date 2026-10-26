import SwiftUI

/// The shared skeleton of the app's two confirmation sheets: the cleanup
/// scan's `CleanConfirmationView` and the app uninstall tool's
/// `AppUninstallConfirmSheet`.
///
/// Both sheets ask the same question in the same shape — here is everything
/// about to be removed, here is what the risks are, confirm or cancel — so
/// the chrome (title block, item list, action row, the 560×600 frame) lives
/// here once and each sheet supplies only its own copy and notices. Two
/// hand-written copies of the skeleton are two paddings to keep in sync, and
/// the progress overlay and result card were componentized for exactly this
/// reason.
///
/// Notices are a slot rather than data: the sheets' notices differ in kind —
/// the cleanup scan's remember prompt is a Toggle, the uninstall tool's
/// leftover catch-up is an action button — and a data model would have to
/// grow a case per notice. The slot keeps each notice's own top spacing
/// (the first notice after the list sits lower than the ones between
/// notices); the horizontal padding is the shell's.
struct ConfirmSheetShell<Notices: View>: View {
    /// The badge's symbol; callers pick the warning glyph when the selection
    /// holds caution-level entries.
    let systemImage: String
    var tint: Color = .accentColor
    /// The sheet's headline.
    let title: String
    /// The line under the title: what is about to happen, counted and sized.
    let summary: String
    /// The checked entries, listed in full. Largest first is the order the
    /// caller passes in.
    let items: [JunkItem]
    /// The real icon of an app bundle; nil falls back to the category symbol.
    var iconFor: (JunkItem) -> NSImage? = { _ in nil }
    /// One row's subtitle, and which end of it gives way. A path loses its
    /// head (the tail names the entry); a plain name loses its tail.
    var subtitleFor: (JunkItem) -> (text: String, truncation: Text.TruncationMode) = { ($0.abbreviatedPath, .head) }
    /// The risk and method notices, each carrying its own top padding.
    @ViewBuilder var notices: () -> Notices
    let confirmTitle: String
    var confirmTint: Color = .accentColor
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            titleArea
                .padding(.top, 24)
                .padding(.bottom, 18)

            itemList
                .padding(.horizontal, 20)

            VStack(spacing: 0) { notices() }
                .padding(.horizontal, 20)

            Spacer(minLength: 16)

            actionRow
                .padding(.bottom, 20)
        }
        .frame(width: 560, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var titleArea: some View {
        VStack(spacing: 12) {
            IconBadge(
                systemImage: systemImage,
                tint: tint,
                diameter: 56,
                symbolSize: 24
            )

            VStack(spacing: 5) {
                Text(verbatim: title)
                    .font(.system(size: 17, weight: .bold))
                Text(verbatim: summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                title: L10n.tr("clean.confirm.list"),
                trailing: L10n.fmt(
                    items.count == 1
                        ? "clean.confirm.listCount.one"
                        : "clean.confirm.listCount.other",
                    items.count
                )
            )

            List(items) { item in
                let subtitle = subtitleFor(item)
                JunkItemRow(
                    item: item,
                    subtitle: subtitle.text,
                    icon: iconFor(item),
                    subtitleTruncation: subtitle.truncation
                )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(L10n.tr("common.cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)

            ProminentActionButton(title: confirmTitle, tint: confirmTint) {
                onConfirm()
            }
        }
    }
}
