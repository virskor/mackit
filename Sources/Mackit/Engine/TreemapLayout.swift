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
/// Items with size 0 get no rect — the view skips them rather than drawing a
/// zero-area tile.
enum TreemapLayout {
    /// Lays `items` out inside a container of `size` (origin at zero).
    /// Returns one rect per item, keyed by id; ids must be unique.
    static func layout(items: [(id: String, size: Int64)], in size: CGSize) -> [String: CGRect] {
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
