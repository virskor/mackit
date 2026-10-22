import AppKit
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

    // MARK: - Tail aggregation

    /// 300×200 with a 2400pt² floor: anything under 4% of the area is folded.
    private let floor: CGFloat = 2_400

    /// Eight 1% children cannot carry a label, so they must not each get a
    /// fragment of the corner: they become one tile, and the big child keeps
    /// its own.
    @Test func tailIsFoldedIntoOneAggregateTile() {
        var items: [Item] = [("big", 92)]
        items.append(contentsOf: (1...8).map { (id: "t\($0)", size: 1) })
        let map = TreemapLayout.layout(items: items, in: container, minTileArea: floor)

        #expect(map.rects.keys.sorted() == ["big"])
        #expect(map.overflow != nil)
        #expect(map.overflow?.ids.count == 8)
        #expect(map.overflow?.size == 8)
        #expect(map.overflow?.ids.contains("big") == false)
        #expect(map.totalSize == 100)
    }

    /// Folding redistributes area, it does not create or destroy it: the big
    /// tile and the aggregate must still cover the container in proportion.
    @Test func foldedTailKeepsAreasProportional() {
        var items: [Item] = [("big", 92)]
        items.append(contentsOf: (1...8).map { (id: "t\($0)", size: 1) })
        let map = TreemapLayout.layout(items: items, in: container, minTileArea: floor)
        let containerArea = 300.0 * 200.0

        let bigArea = (map.rects["big"].map { $0.width * $0.height }) ?? 0
        let tailArea = (map.overflow.map { $0.rect.width * $0.rect.height }) ?? 0
        #expect(abs(bigArea - 0.92 * containerArea) / containerArea < 0.02)
        #expect(abs(tailArea - 0.08 * containerArea) / containerArea < 0.02)
        #expect(abs(bigArea + tailArea - containerArea) / containerArea < 0.02)
    }

    /// One small child is not noise: a "其余 1 项" tile would be a label the
    /// user cannot act on, so it keeps its own rect.
    @Test func singleSmallItemIsNotFolded() {
        let items: [Item] = [("big", 97), ("small", 3)]
        let map = TreemapLayout.layout(items: items, in: container, minTileArea: floor)
        #expect(map.overflow == nil)
        #expect(map.rects.keys.sorted() == ["big", "small"])
    }

    @Test func childrenAboveTheFloorKeepTheirOwnTile() {
        let items: [Item] = [("a", 25), ("b", 25), ("c", 25), ("d", 25)]
        let map = TreemapLayout.layout(items: items, in: container, minTileArea: floor)
        #expect(map.overflow == nil)
        #expect(map.rects.count == 4)
    }

    /// A window too small to hold even one readable tile collapses the whole
    /// map into the aggregate: an honest "18 项, go look at the list" beats a
    /// grid of unreadable slivers.
    @Test func containerTooSmallForAnyTileFoldsEverything() {
        let items: [Item] = (1...10).map { (id: "i\($0)", size: 10) }
        let map = TreemapLayout.layout(
            items: items,
            in: CGSize(width: 100, height: 100),
            minTileArea: floor
        )
        #expect(map.rects.isEmpty)
        #expect(map.overflow?.ids.count == 10)
        #expect(map.overflow?.rect == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    /// The aggregate must behave like a tile of its size: inside the container,
    /// and clear of every kept tile.
    @Test func aggregateDoesNotOverlapKeptTiles() {
        let items: [Item] = [("big", 600), ("mid", 200), ("mid2", 120)]
            + (1...12).map { (id: "t\($0)", size: Int64($0)) }
        let map = TreemapLayout.layout(
            items: items,
            in: CGSize(width: 480, height: 320),
            minTileArea: floor
        )
        guard let aggregate = map.overflow?.rect else {
            Issue.record("expected a folded tail")
            return
        }
        #expect(aggregate.minX >= -0.5 && aggregate.minY >= -0.5)
        #expect(aggregate.maxX <= 480.5 && aggregate.maxY <= 320.5)
        for (id, rect) in map.rects {
            let overlap = aggregate.intersection(rect)
            let area = max(0, overlap.width) * max(0, overlap.height)
            #expect(area < 0.5, "aggregate overlaps \(id) by \(area)")
        }
    }
}

/// The label rule (`TreemapLabel`) has to agree with the fold threshold
/// (`TreemapLayout.readableArea`): one decides which children get a tile, the
/// other decides what that tile can say. Both are pure, so both are pinned
/// here — including the widths, measured against the real system font, that
/// the previous fixed-pixel thresholds got wrong.
struct TreemapLabelTests {
    @Test func boundaryTilesGetTheLabelTheyCanHold() {
        #expect(TreemapLabel.room(for: CGSize(width: 96, height: 64)) == .full)
        #expect(TreemapLabel.room(for: CGSize(width: 95, height: 64)) == .name)
        // Height alone is not enough for the third line.
        #expect(TreemapLabel.room(for: CGSize(width: 200, height: 63)) == .name)
        #expect(TreemapLabel.room(for: CGSize(width: 46, height: 20)) == .name)
        #expect(TreemapLabel.room(for: CGSize(width: 45, height: 20)) == .none)
        #expect(TreemapLabel.room(for: CGSize(width: 200, height: 19)) == .none)
    }

    /// Growing a tile must never take a label away — the layout hands out
    /// arbitrary rects and a non-monotonic rule would make a resized window
    /// flip labels on and off.
    @Test func roomNeverShrinksAsTheTileGrows() {
        let order: [TreemapLabel.Room] = [.none, .name, .full]
        func rank(_ room: TreemapLabel.Room) -> Int { order.firstIndex(of: room) ?? 0 }

        var widths = Array(stride(from: CGFloat(4), through: 220, by: 1))
        widths += [46, 96, 95, 200]
        for width in widths {
            var previous = 0
            for height in stride(from: CGFloat(4), through: 220, by: 1) {
                let current = rank(TreemapLabel.room(for: CGSize(width: width, height: height)))
                #expect(current >= previous, "\(width)×\(height) lost its label as it grew")
                previous = current
            }
        }
    }

    /// The `.full` label's second line is the widest thing a tile draws:
    /// "999.99GB·100%" at 10pt. If it does not fit the 84pt of text a `.full`
    /// tile promises, every large tile truncates its size and share. The
    /// separator carries no spaces for exactly this reason — the spaced form
    /// needs ~87pt, which the first version of this line silently overflowed.
    ///
    /// Measured through the catalog rather than a literal: the line is built
    /// by `L10n.fmt`, so this is the string the view will actually draw. All
    /// three languages keep the unspaced form, because the 84pt threshold was
    /// measured against it — a translation that added spaces would fail here.
    @Test func fullLabelLineFitsTheWidthItPromises() {
        let textWidth = 96 - TreemapLabel.inset
        let line = L10n.fmt("diskAnalysis.tile.sizeShare", "999.99GB", "100%")
        let measured = (line as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10)
        ]).width
        #expect(measured <= textWidth, "the size/share line needs \(measured)pt, the tile offers \(textWidth)pt")

        // The hover card's spaced form is what must stay out of the tile.
        let spaced = L10n.fmt("diskAnalysis.hover.sizeShare", "999.99GB", "100%")
        #expect(spaced != line, "the two size/share lines must differ in their separator")
        let spacedWidth = (spaced as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 10)
        ]).width
        #expect(spacedWidth > textWidth, "the spaced form must stay out of the tile — it does not fit")
    }

    /// The `.name` minimum must still show something: at least two glyphs plus
    /// the ellipsis, or the tile holds a "…" and nothing else.
    @Test func nameLabelKeepsAFewGlyphsAtItsMinimumWidth() {
        let textWidth = 46 - TreemapLabel.inset
        let probe = "元宝…"
        let measured = (probe as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 11)
        ]).width
        #expect(measured <= textWidth, "\(probe) needs \(measured)pt, the tile offers \(textWidth)pt")
    }
}
