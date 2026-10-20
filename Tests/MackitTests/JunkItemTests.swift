import Foundation
import Testing

@testable import Mackit

/// Verifies that display fields are precomputed at creation and updated in sync with size.
struct JunkItemTests {
    private func makeItem(
        title: String = "DerivedData",
        detail: String = "Xcode",
        path: String = "/tmp/mackit-test",
        size: Int64 = 0
    ) -> JunkItem {
        JunkItem(
            ruleID: "xcode.derived",
            title: title,
            detail: detail,
            path: path,
            category: .xcode,
            risk: .safe,
            size: size
        )
    }

    /// sizeText must match size at creation and update in sync with subsequent
    /// modifications — cells render this field directly instead of calling the
    /// formatter every time.
    @Test func sizeTextTracksSize() {
        let item = makeItem(size: 1024 * 1024)
        #expect(item.sizeText == Formatters.bytes(1024 * 1024))
        #expect(!item.isUnknownSize)

        var mutated = item
        mutated.size = 0
        #expect(mutated.sizeText == Formatters.bytes(0))
        #expect(mutated.isUnknownSize)
    }

    /// In a default construction (unmeasured), size is 0, which counts as an unknown size.
    @Test func unmeasuredItemHasUnknownSize() {
        let item = makeItem()
        #expect(item.size == 0)
        #expect(item.isUnknownSize)
    }

    /// The home prefix is abbreviated to ~, and other paths are kept as-is.
    @Test func abbreviatedPathReplacesHomePrefix() {
        let home = NSHomeDirectory()
        let inside = makeItem(path: home + "/Library/Caches/foo")
        #expect(inside.abbreviatedPath == "~/Library/Caches/foo")

        let outside = makeItem(path: "/var/tmp/foo")
        #expect(outside.abbreviatedPath == "/var/tmp/foo")

        // home itself is abbreviated to ~
        #expect(makeItem(path: home).abbreviatedPath == "~")

        // The prefix must land on a directory boundary: another user whose name
        // starts with the current user's name (/Users/weizhang2) must not be
        // abbreviated to ~2
        let sibling = makeItem(path: home + "2/Library/Caches")
        #expect(sibling.abbreviatedPath == home + "2/Library/Caches", "the sibling home directory was wrongly abbreviated: \(sibling.abbreviatedPath)")

        let commandItem = JunkItem(
            ruleID: "go.clean",
            title: "go clean",
            detail: "Go",
            path: "",
            category: .go,
            risk: .safe,
            isCommand: true,
            command: ["go", "clean", "-cache"]
        )
        #expect(commandItem.abbreviatedPath.isEmpty)
        #expect(commandItem.displayPath == "go clean -cache")
    }

    /// The search blob covers title, detail, and path, and is lowercased, so
    /// each keystroke in the search box needs only one contains call instead of
    /// lowercased() per item.
    @Test func searchBlobCoversTitleDetailAndPath() {
        let item = makeItem(
            title: "DerivedData",
            detail: "Xcode",
            path: "/Users/someone/Library/Developer/Xcode/DerivedData"
        )
        #expect(item.searchBlob.contains("deriveddata"))
        #expect(item.searchBlob.contains("xcode"))
        #expect(item.searchBlob.contains("/users/someone/library"))
        #expect(item.searchBlob == item.searchBlob.lowercased())
    }
}
