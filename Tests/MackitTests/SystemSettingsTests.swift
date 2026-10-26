import Foundation
import Testing

@testable import Mackit

/// The deep link behind every "open settings" button.
///
/// System Settings does not error on an unknown pane id or anchor: it simply
/// opens somewhere else, so a typo in the URL ships as a button that reads as
/// a no-op. The parts are pinned against the parsed URL rather than the
/// source string — the scheme, the pane and the row are what the OS matches.
struct SystemSettingsTests {
    @Test func fullDiskAccessLinkTargetsTheSecurityPane() {
        let url = SystemSettings.fullDiskAccess

        #expect(url.scheme == "x-apple.systempreferences")
        #expect(url.path() == "com.apple.preference.security")
        #expect(url.query == "Privacy_AllFiles")
    }
}
