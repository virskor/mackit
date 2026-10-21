import Foundation

/// Squarified treemap layout (Bruls, Huizing & van Wijk, 2000).
///
/// Pure function over ids + sizes: the view only renders the rects, so the
/// layout can be tested without SwiftUI. Areas are proportional to the item
/// sizes; items are laid out largest-first in rows along the shorter side of
/// the remaining space, each row chosen so the worst tile aspect ratio stays
/// as close to 1 as the sizes allow (a plain slice-and-dice would produce
/// needle-thin tiles).
///
/// Two entry points. `layout(items:in:)` lays every item out proportionally.
/// `layout(items:in:minTileArea:)` first folds the tail — every item too small
/// to carry a label — into a single aggregate tile. Strict proportionality
/// alone turns a folder with a few huge children and forty small ones
/// (Applications: a 5.8 GB IDE next to a 300 MB helper) into a field of
/// unlabelled fragments in one corner, which reads as noise rather than as a
/// breakdown. Folding keeps every large item's true area and gives the tail one
/// readable block inside the area it actually occupies.
///
/// Items with size 0 get no rect — the view skips them rather than drawing a
/// zero-area tile.
enum TreemapLayout {
    /// A tile smaller than this many square points cannot carry a readable
    /// label: 11pt text needs roughly 34pt of width and 20pt of height, and the
    /// tile's own insets and the gap between tiles eat the rest. Under this the
    /// name is either dropped or drawn as a fragment ("元宝.ap" with "p" below
    /// it), which is worse than no name at all.
    ///
    /// 3,200pt² (≈57×57) comes from the layouts this page actually produces,
    /// not from a round guess: squarified tiles come out elongated, so a 42×69
    /// strip clears a plain area test while leaving 30pt for its name — exactly
    /// the unlabelled tile this threshold exists to prevent. Replayed against a
    /// 51-child Applications listing (5.79 GB down to 0.2 GB) in a 660×500
    /// card, this value leaves 13 full labels, 8 name-only labels and no bare
    /// tile; at 2,400 two strips stayed blank.
    static let readableArea: CGFloat = 3_200

    /// One layout pass: a rect per drawn item, plus the folded tail when the
    /// caller asked for aggregation.
    struct Map: Equatable {
        var rects: [String: CGRect]
        /// The aggregate tile; nil when nothing was folded.
        var overflow: Overflow?
        /// Sum of the sizes that were laid out, folded tail included — the
        /// basis for expressing a single tile as a share of the folder.
        var totalSize: Int64

        static let empty = Map(rects: [:], overflow: nil, totalSize: 0)
    }

    /// The folded tail: the items too small for a tile of their own, and the
    /// rect their combined area was given.
    struct Overflow: Equatable {
        /// Ids of the folded items, in the order the caller passed them (the
        /// model hands children over size-descending, so normally largest
        /// first). The caller holds the entries and resolves them from here.
        let ids: [String]
        /// Sum of the folded items' sizes — what the aggregate tile labels.
        let size: Int64
        let rect: CGRect
    }

    /// Sentinel id for the aggregate tile. A path cannot contain NUL, so no real
    /// entry can collide with it. It never leaves this type: callers receive
    /// `Overflow.rect` instead.
    private static let aggregateID = "\u{0}aggregate"

    /// Lays `items` out inside a container of `size` (origin at zero), strictly
    /// proportionally. Returns one rect per item, keyed by id; ids must be
    /// unique.
    static func layout(items: [(id: String, size: Int64)], in size: CGSize) -> [String: CGRect] {
        squarify(items: items, in: size)
    }

    /// Same layout, with every item below `minTileArea` folded into one
    /// aggregate tile.
    ///
    /// A lone unreadable item is left alone: one small tile is not noise, and a
    /// "其余 1 项" tile would be a label the user cannot act on.
    ///
    /// `minTileArea` has no default on purpose: a default would make every
    /// two-argument call ambiguous with the proportional overload above.
    static func layout(
        items: [(id: String, size: Int64)],
        in size: CGSize,
        minTileArea: CGFloat
    ) -> Map {
        let measured = items.filter { $0.size > 0 }
        let total = measured.reduce(Int64(0)) { $0 + $1.size }
        guard size.width > 0, size.height > 0, total > 0 else { return .empty }

        // Shares rather than raw areas: the comparison stays exact for any
        // container size, and rounding never decides membership.
        let floorShare = Double(minTileArea) / Double(size.width * size.height)
        let head = measured.filter { Double($0.size) / Double(total) >= floorShare }
        let tail = measured.filter { Double($0.size) / Double(total) < floorShare }
        guard tail.count >= 2 else {
            return Map(rects: squarify(items: measured, in: size), overflow: nil, totalSize: total)
        }

        let tailSize = tail.reduce(Int64(0)) { $0 + $1.size }
        var laidOut = head
        laidOut.append((id: aggregateID, size: tailSize))
        let rects = squarify(items: laidOut, in: size)

        // Degenerate containers can leave the aggregate tile without a rect;
        // then the head is still worth drawing and the tail stays invisible
        // rather than taking area that nothing accounts for.
        guard let rect = rects[aggregateID] else {
            return Map(
                rects: rects.filter { $0.key != aggregateID },
                overflow: nil,
                totalSize: total
            )
        }
        return Map(
            rects: rects.filter { $0.key != aggregateID },
            overflow: Overflow(ids: tail.map(\.id), size: tailSize, rect: rect),
            totalSize: total
        )
    }

    /// The squarified pass itself: no aggregation, one rect per non-zero item.
    private static func squarify(
        items: [(id: String, size: Int64)],
        in size: CGSize
    ) -> [String: CGRect] {
        var rects: [String: CGRect] = [:]
        guard size.width > 0, size.height > 0, !items.isEmpty else { return rects }

        let sorted = items
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
        let total = sorted.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return rects }

        let fullArea = size.width * size.height
        var free = CGRect(origin: .zero, size: size)
        var index = 0

        while index < sorted.count {
            // A row spans the shorter side of the free rect and extends by its
            // thickness along the longer one; each tile is a share of the
            // shorter side long and the row's thickness wide.
            let side = min(free.width, free.height)
            // A sliver left by floating-point drift can't hold another row;
            // the remaining items get nothing (only reachable with absurd size
            // ratios, and the view renders only the top tiles anyway).
            guard side > 0.5 else { break }

            // Grow the row while the worst tile aspect ratio keeps improving.
            var rowSum: Int64 = 0
            var rowCount = 0
            var bestWorst = Double.greatestFiniteMagnitude
            while index + rowCount < sorted.count {
                let candidateSum = rowSum + sorted[index + rowCount].size
                let candidateThickness = Double(candidateSum) / Double(total) * fullArea / side
                let worst = worstAspect(
                    values: sorted[index...(index + rowCount)].map(\.size),
                    sum: candidateSum,
                    side: side,
                    thickness: candidateThickness
                )
                if rowCount > 0, worst > bestWorst { break }
                rowSum = candidateSum
                rowCount += 1
                bestWorst = worst
            }

            let rowArea = Double(rowSum) / Double(total) * fullArea
            let thickness = rowArea / side
            let horizontal = free.width <= free.height
            var cursor: CGFloat = 0
            for offset in 0..<rowCount {
                let item = sorted[index + offset]
                let length = Double(item.size) / Double(rowSum) * side
                let rect: CGRect
                if horizontal {
                    rect = CGRect(x: free.minX + cursor, y: free.minY, width: length, height: thickness)
                    cursor += length
                } else {
                    rect = CGRect(x: free.minX, y: free.minY + cursor, width: thickness, height: length)
                    cursor += length
                }
                if rect.width > 0, rect.height > 0 {
                    rects[item.id] = rect
                }
            }

            // Shrink the free rect by the row's thickness on the side it was
            // laid against, keeping the remainder a rectangle.
            if horizontal {
                free = CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: free.height - thickness)
            } else {
                free = CGRect(x: free.minX + thickness, y: free.minY, width: free.width - thickness, height: free.height)
            }
            index += rowCount
        }

        return rects
    }

    /// Worst aspect ratio among a row's tiles: every tile is `side` long in
    /// one dimension and `thickness` in the other, scaled by its share of the
    /// row.
    private static func worstAspect(
        values: [Int64],
        sum: Int64,
        side: CGFloat,
        thickness: CGFloat
    ) -> Double {
        guard thickness > 0, sum > 0 else { return .greatestFiniteMagnitude }
        var worst = 0.0
        for value in values {
            let length = Double(value) / Double(sum) * side
            let aspect = max(length / thickness, thickness / length)
            worst = max(worst, aspect)
        }
        return worst
    }
}

/// What a tile can write inside the rect it was given.
///
/// This lives beside `TreemapLayout.readableArea` on purpose. The fold
/// threshold and the label thresholds describe the same thing — the smallest
/// tile that still reads — so they only stay consistent if they are read and
/// edited together; while the rule sat inside the view, the two drifted apart
/// (a 48pt tile passed the label check with 12pt of it already spent on insets)
/// and nothing could test the pair.
///
/// Pure geometry plus two font sizes: no SwiftUI, so the view and the test see
/// exactly the same rule.
enum TreemapLabel {
    /// How much of a tile is unavailable to text.
    enum Room: Equatable {
        /// Nothing fits — a name here would be a fragment.
        case none
        /// One line of 11pt name, truncated.
        case name
        /// Icon, name, and the size/share line.
        case full
    }

    /// The tile's own 2pt inset on each side plus the label's 4pt gutter: what
    /// a name loses before a single glyph is laid out.
    static let inset: CGFloat = 12

    /// The label a tile of `tile` size can carry.
    ///
    /// Measured on the text area, not on the tile — 48pt of tile leaves 36pt of
    /// text, where an 11pt CJK name needs ~55pt, which is how "元宝.app" passed
    /// a plain width check and then wrapped mid-word.
    ///
    /// 84pt of text (a 96pt tile) is enough only because the tile's size/share
    /// line is written without spaces around its separator ("999.99GB·100%"
    /// measures ~81pt at 10pt; the spaced version needs ~87pt and truncated on
    /// every large tile). `TreemapLabelTests` measures both against the real
    /// font — change the line's format and that test is the one that complains.
    static func room(for tile: CGSize) -> Room {
        let width = tile.width - inset
        if width >= 84, tile.height >= 64 { return .full }
        if width >= 34, tile.height >= 20 { return .name }
        return .none
    }
}
