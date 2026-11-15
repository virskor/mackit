import Foundation

/// The tray panel's pages.
///
/// The raw value doubles as the localization key suffix, so a tab's title in
/// the picker and a page's own header cannot drift apart: both resolve the
/// same `panel.tab.<rawValue>` entry.
enum PanelTab: String, CaseIterable, Identifiable {
    case overview
    case processor
    case memory

    var id: String { rawValue }

    var title: String { L10n.tr("panel.tab.\(rawValue)") }
}
