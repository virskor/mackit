import Foundation
import Testing

@testable import Mackit

/// Unit tests for the bundle-version formatter shared by the About page and
/// the update controller's bundle-replacement marker.
struct AppVersionTests {
    @Test func bothPartsPresentAppendsBuildInParens() {
        #expect(AppVersion.format(shortVersion: "1.0.4", build: "152") == "1.0.4 (152)")
    }

    @Test func buildEqualToShortVersionIsNotRepeated() {
        #expect(AppVersion.format(shortVersion: "1.0.4", build: "1.0.4") == "1.0.4")
    }

    @Test func missingBuildKeepsShortVersionAlone() {
        #expect(AppVersion.format(shortVersion: "1.0.4", build: nil) == "1.0.4")
        #expect(AppVersion.format(shortVersion: "1.0.4", build: "") == "1.0.4")
    }

    /// A missing short version must degrade to the build number alone, not a
    /// string with a dangling " (" — this is what the About page used to do
    /// before the two call sites shared one formatter.
    @Test func missingShortVersionFallsBackToBuild() {
        #expect(AppVersion.format(shortVersion: nil, build: "152") == "152")
        #expect(AppVersion.format(shortVersion: "", build: "152") == "152")
    }

    @Test func neitherPartReadableReturnsNil() {
        #expect(AppVersion.format(shortVersion: nil, build: nil) == nil)
        #expect(AppVersion.format(shortVersion: "", build: "") == nil)
    }

    /// Whatever the test host bundle carries, the result must be a usable
    /// string — never empty and never the dangling-" (" shape the formatter
    /// rules out.
    @Test func mainBundleDisplayIsWellFormed() {
        if let display = AppVersion.display {
            #expect(!display.isEmpty)
            #expect(!display.hasPrefix(" ("))
        }
    }
}
