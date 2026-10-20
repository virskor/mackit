import Foundation
import Testing

@testable import Mackit

/// The treemap layout is the disk analysis page's visual core: tiles must be
/// area-proportional, stay inside the container, and never overlap. These are
/// the properties the view relies on and the user would notice immediately.
struct TreemapLayoutTests {
    typealias Item = (id: String, size: Int64)

    private let container = CGSize(width: 300, height: 200)

    @Test func singleItemFillsTheContainer() {
        let items: [Item] = [("a", 10)]
        let rects = TreemapLayout.layout(items: items, in: container)
        #expect(rects.count == 1)
        #expect(rects["a"] == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func emptyInputYieldsNothing() {
        #expect(TreemapLayout.layout(items: [] as [Item], in: container).isEmpty)
        #expect(TreemapLayout.layout(items: [] as [Item], in: .zero).isEmpty)
    }

    /// Zero-size entries (empty folders) get no rect: a zero-area tile can't
    /// be clicked or seen, and reserving space for it would distort the rest.
    @Test func zeroSizeItemsGetNoRect() {
        let items: [Item] = [("a", 10), ("b", 0)]
        let rects = TreemapLayout.layout(items: items, in: container)
        #expect(rects.count == 1)
        #expect(rects["b"] == nil)
    }

    @Test func areasAreProportionalToSizes() {
        let items: [Item] = [("a", 60), ("b", 30), ("c", 10)]
        let rects = TreemapLayout.layout(items: items, in: container)
        let containerArea = 300.0 * 200.0
        for (id, size) in items {
            let expected = Double(size) / 100.0 * containerArea
            let rect = rects[id]
            #expect(rect != nil, "\(id) missing")
            if let rect {
                let actual = rect.width * rect.height
                #expect(abs(actual - expected) / expected < 0.02, "\(id) area \(actual), expected \(expected)")
            }
        }
    }

    @Test func rectsStayInsideTheContainer() {
        let items: [Item] = (1...20).map { (id: "i\($0)", size: Int64($0 * $0)) }
        let rects = TreemapLayout.layout(items: items, in: container)
        for (id, rect) in rects {
            #expect(rect.minX >= -0.5, "\(id) starts left of the container")
            #expect(rect.minY >= -0.5, "\(id) starts above the container")
            #expect(rect.maxX <= 300.5, "\(id) overflows the right edge")
            #expect(rect.maxY <= 200.5, "\(id) overflows the bottom edge")
        }
    }

    /// Overlap would hide one tile behind another; edge-touching is fine
    /// (that is how a treemap tiles), so only positive overlap area counts.
    @Test func tilesDoNotOverlap() {
        let items: [Item] = (1...16).map { (id: "i\($0)", size: Int64($0 * 3)) }
        let rects = TreemapLayout.layout(items: items, in: container)
        let all = Array(rects.values)
        for i in all.indices {
            for j in (i + 1)..<all.count {
                let intersection = all[i].intersection(all[j])
                let overlap = max(0, intersection.width) * max(0, intersection.height)
                #expect(overlap < 0.5, "tiles overlap by \(overlap)")
            }
        }
    }

    /// The point of squarified over slice-and-dice: equal tiles must stay
    /// roughly square instead of degenerating into needles.
    @Test func equalSizesStayRoughlySquare() {
        let items: [Item] = (0..<16).map { (id: "t\($0)", size: 1) }
        let rects = TreemapLayout.layout(items: items, in: CGSize(width: 400, height: 400))
        #expect(rects.count == 16)
        var worstAspect = 1.0
        for rect in rects.values {
            worstAspect = max(worstAspect, max(rect.width / rect.height, rect.height / rect.width))
        }
        #expect(worstAspect < 2.5, "worst tile aspect ratio is \(worstAspect)")
    }

    /// A dominating entry (one 2 GB folder among kilobytes of caches) must
    /// still claim its share — the treemap exists to show exactly that.
    @Test func dominatingItemClaimsItsShare() {
        let items: [Item] = [("big", 99), ("small", 1)]
        let rects = TreemapLayout.layout(items: items, in: container)
        let containerArea = 300.0 * 200.0
        let bigArea = rects["big"].map { $0.width * $0.height } ?? 0
        #expect(abs(bigArea - 0.99 * containerArea) / containerArea < 0.02)
    }

    /// The layout sorts internally, so the caller's order (the list's size
    /// ordering, or the streaming arrival order) must not change the result.
    @Test func inputOrderDoesNotMatter() {
        let ordered: [Item] = [("a", 50), ("b", 30), ("c", 20)]
        let shuffled: [Item] = [("c", 20), ("a", 50), ("b", 30)]
        #expect(
            TreemapLayout.layout(items: ordered, in: container)
                == TreemapLayout.layout(items: shuffled, in: container)
        )
    }

    /// Extreme ratios (squares of 1…200, a 40000:1 spread) must still produce
    /// in-bounds rects, with the visually dominant items always present.
    @Test func extremeSizeRatiosStayInBounds() {
        let items: [Item] = (1...200).map { (id: "i\($0)", size: Int64($0 * $0)) }
        let rects = TreemapLayout.layout(items: items, in: CGSize(width: 800, height: 600))
        #expect(rects["i200"] != nil, "the largest item must always get a rect")
        #expect(rects["i100"] != nil, "a mid-size item must get a rect")
        for (id, rect) in rects {
            #expect(rect.minX >= -0.5 && rect.minY >= -0.5, "\(id) outside the top-left")
            #expect(rect.maxX <= 800.5 && rect.maxY <= 600.5, "\(id) outside the bottom-right")
        }
    }
}
