import Foundation
import Testing

@testable import Mackit

/// Unit tests for the auto-update controller.
///
/// Covers two kinds of logic that do not depend on the Sparkle runtime: feed
/// configuration checks (which decide whether dev builds enable updates) and
/// the two branches of the "Last check" copy. Sparkle's own
/// download / signature verification / replacement is guaranteed by the
/// end-to-end flow in Scripts/build-update.sh, outside the scope of unit tests.
struct UpdateControllerTests {
    // MARK: - feed configuration checks

    @Test func feedURLEmptyOrMissingDisablesUpdater() {
        #expect(!UpdateController.isEnabled(feedURL: nil))
        #expect(!UpdateController.isEnabled(feedURL: ""))
    }

    @Test func feedURLPresentEnablesUpdater() {
        #expect(UpdateController.isEnabled(feedURL: "https://example.com/appcast.xml"))
    }

    // MARK: - "Last check" copy

    @Test @MainActor func lastCheckNeverUsesNeverString() {
        let description = UpdateController.lastCheckDescription(for: nil)
        #expect(description == L10n.tr("settings.update.lastCheckNever"))
    }

    @Test @MainActor func lastCheckWithDatePrefixesLocalizedLabel() {
        // Use a time definitely in the past, to avoid the relative time Formatter
        // returning boundary values like "just now"; the expected value is derived
        // with the same placeholder format string, so it does not depend on any
        // specific language's copy.
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        let description = UpdateController.lastCheckDescription(for: date)
        let expectedPrefix = L10n.fmt("settings.update.lastCheck", "")
        #expect(description.hasPrefix(expectedPrefix))
        #expect(description.count > expectedPrefix.count)
    }

    // MARK: - Localization key completeness

    /// All update-related keys used by the settings page and the App menu must
    /// be in the catalog: on a failed lookup Foundation returns the key as-is,
    /// which is used to spot missing translations.
    @Test func updateKeysResolveFromCatalog() {
        let keys = [
            "menu.checkForUpdates",
            "settings.update.header",
            "settings.update.autoCheck",
            "settings.update.autoDownload",
            "settings.update.check",
            "settings.update.lastCheck",
            "settings.update.lastCheckNever",
            "settings.update.footer",
        ]
        for key in keys {
            #expect(L10n.tr(key) != key, "\(key) 未本地化")
        }
    }
}
