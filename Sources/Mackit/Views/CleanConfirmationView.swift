import SwiftUI

/// Clean confirmation panel: before cleaning, the full list must be shown and
/// the user must explicitly confirm.
///
/// The panel itself holds no state; show and dismiss are both driven by
/// vm.cleanPhase, avoiding the problem of "after cancel, cleanPhase gets stuck
/// at .confirming, so clicking again doesn't pop up the panel".
///
/// Uninstalling apps is not confirmed here: the app uninstall tool has its
/// own page and its own sheet, because its subject (installed apps and their
/// leftover files) is no longer part of the cleanup scan.
struct CleanConfirmationView: View {
    @Environment(AppViewModel.self) private var vm

    /// The "remember this selection" prompt, off by default: remembering
    /// rewrites what every later scan pre-checks, so it has to be the user's
    /// explicit choice. Defaulted on, a one-off "check the whole group and
    /// clean once" gesture was silently saved and re-checked the entire page
    /// on the next scan — the clean looked like it had accomplished nothing.
    /// Reset on every presentation because the sheet builds its content
    /// fresh each time.
    @State private var rememberSelection = false

    /// Sorted by size from large to small, largest first for easy verification.
    private var items: [JunkItem] { vm.selectedItems.sorted { $0.size > $1.size } }
    private var hasCaution: Bool { items.contains { $0.risk == .caution } }
    /// Review-level entries other than language packs. The generic review
    /// notice ("re-downloaded or rebuilt") is written for exactly these:
    /// caches, toolchain stores, downloaded archives and firmware.
    private var hasOtherReview: Bool {
        items.contains { $0.risk == .review && $0.category != .language }
    }
    /// How many language packs are about to be removed. They get their own
    /// notice: "caches … slower first build" says nothing true about them.
    private var languagePackCount: Int { items.count { $0.category == .language } }

    /// One row of the confirmation list.
    private func row(for item: JunkItem) -> some View {
        let subtitle = subtitle(for: item)
        return JunkItemRow(
            item: item,
            subtitle: subtitle.text,
            subtitleTruncation: subtitle.truncation
        )
    }

    /// The subtitle of one list row, and how it may be truncated. A language
    /// pack is titled by its own code ("ja.lproj"), so the app it belongs to
    /// goes in the subtitle: the path would be truncated at the head, cutting
    /// off exactly that name. Every other row shows a path, which gives way at
    /// the head because its tail names the entry.
    private func subtitle(for item: JunkItem) -> (text: String, truncation: Text.TruncationMode) {
        if item.category == .language, let appName = item.appName, !appName.isEmpty {
            return (appName, .tail)
        }
        return (item.abbreviatedPath, .head)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title area
            VStack(spacing: 12) {
                IconBadge(
                    systemImage: hasCaution ? "exclamationmark.triangle.fill" : "trash.fill",
                    tint: hasCaution ? .red : .accentColor,
                    diameter: 56,
                    symbolSize: 24
                )

                VStack(spacing: 5) {
                    Text(L10n.tr("clean.confirm.title"))
                        .font(.system(size: 17, weight: .bold))
                    Text(verbatim: L10n.fmt(
                        items.count == 1
                            ? "clean.confirm.summary.one"
                            : "clean.confirm.summary.other",
                        items.count,
                        Formatters.bytes(vm.selectedSize)
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 18)

            // Item list: shows all checked items in full, no truncation
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
                    row(for: item)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .padding(.horizontal, 20)

            // Risk notice
            if hasCaution {
                NoticeRow(
                    systemImage: "exclamationmark.octagon.fill",
                    tint: .red,
                    title: L10n.tr("clean.confirm.cautionTitle"),
                    message: L10n.tr("clean.confirm.cautionMessage")
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)
            } else if hasOtherReview {
                NoticeRow(
                    systemImage: "exclamationmark.circle.fill",
                    tint: .orange,
                    title: L10n.tr("clean.confirm.reviewTitle"),
                    message: L10n.tr("clean.confirm.reviewMessage")
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            // Language packs say what they actually do. The review wording
            // above describes caches ("first build will be slower"), which is
            // not what happens here: the affected apps' interfaces fall back to
            // English or another language until they are reinstalled or
            // updated. That is what the user has to agree to.
            if languagePackCount > 0 {
                NoticeRow(
                    systemImage: "character.book.closed.fill",
                    tint: .orange,
                    title: L10n.tr("clean.confirm.languageTitle"),
                    message: L10n.fmt("clean.confirm.languageMessage", languagePackCount)
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            // Clean method
            NoticeRow(
                systemImage: vm.moveToTrash ? "trash" : "bolt.fill",
                message: vm.moveToTrash
                    ? L10n.tr("clean.confirm.toTrash")
                    : L10n.tr("clean.confirm.permanent")
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // The user curated the general module's rows differently from
            // what the next scan would pre-check: offer to remember that
            // curation. Off by default, so a selection made for one clean is
            // never saved behind the user's back.
            if vm.showsRememberGeneralPrompt {
                rememberRow
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            Spacer(minLength: 16)

            // Buttons
            HStack(spacing: 10) {
                Button(L10n.tr("common.cancel")) { vm.cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)

                ProminentActionButton(
                    title: hasCaution
                        ? L10n.tr("clean.confirm.cleanAnyway")
                        : L10n.tr("clean.confirm.cleanNow"),
                    tint: hasCaution ? .red : .accentColor
                ) {
                    // Only when the prompt is actually showing: the toggle
                    // is off by default and only ever set on the general
                    // module's sheet, so without the guard a clean launched
                    // from elsewhere could still save a selection.
                    if rememberSelection && vm.showsRememberGeneralPrompt {
                        vm.rememberGeneralSelection()
                    }
                    vm.beginClean()
                }
            }
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The remember-this-selection row: an inline toggle rather than a
    /// NoticeRow, which only offers a one-shot action button.
    private var rememberRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: L10n.tr("general.remember.title"))
                    .font(.system(size: 12, weight: .semibold))
                Text(verbatim: L10n.tr("general.remember.message"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle(isOn: $rememberSelection) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}
