import Foundation

/// The app bundle's version, as shown in the About page and compared by the
/// update controller to tell whether the bundle was replaced since the last
/// launch.
///
/// One formatter for both call sites: the About page's version row and the
/// update controller's bundle-replacement marker must never drift apart, or
/// the marker would stop matching the displayed version and restart the tray
/// agent on every launch.
enum AppVersion {
    /// The running bundle's version, read from its Info.plist. Nil when
    /// neither key can be read (see `format`).
    static var display: String? {
        Self.format(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// The formatting rule on its own, separated from the bundle read so every
    /// combination is testable. A missing key reads as nil, same as empty —
    /// both mean "the build script did not write it".
    static func format(shortVersion: String?, build: String?) -> String? {
        let version = shortVersion ?? ""
        let buildNumber = build ?? ""
        if version.isEmpty { return buildNumber.isEmpty ? nil : buildNumber }
        if buildNumber.isEmpty || buildNumber == version { return version }
        return "\(version) (\(buildNumber))"
    }
}
