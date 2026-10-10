import CoreGraphics

/// Squarified treemap layout of a flat list (Bruls, Huizing and van Wijk, "Squarified Treemaps", 2000).
/// Coordinates are y-down, as in SwiftUI: the heaviest weight lands at the top left.
nonisolated enum SquarifiedLayout {
    /// One rect per weight, in input order. Areas are proportional to the weights, fill `rect` and do not overlap.
    /// Weights that are zero, negative or not finite get a zero-size rect, as does every weight when `rect` has no
    /// area. Equal weights are placed in input order, so the result depends on nothing but the arguments.
    static func rects(for weights: [Double], in rect: CGRect) -> [CGRect] {
        let weights = weights.map(usable)
        let order = heaviestFirst(Array(weights.indices), by: weights)
        let placed = layout(sortedWeights: order.map { weights[$0] }, in: rect).rects
        let empty = CGRect(origin: rect.isNull ? .zero : rect.standardized.origin, size: .zero)
        var rects = Array(repeating: empty, count: weights.count)
        for (position, index) in order.prefix(placed.count).enumerated() {
            rects[index] = placed[position]
        }
        return rects
    }

    /// `indices` into `weights`, sorted heaviest first; equal weights keep the order of their indices.
    static func heaviestFirst(_ indices: [Int], by weights: [Double]) -> [Int] {
        indices.sorted { weights[$0] > weights[$1] || (weights[$0] == weights[$1] && $0 < $1) }
    }

    /// The weight the layout uses: zero for negative, NaN and infinite values.
    static func usable(_ weight: Double) -> Double {
        weight.isFinite && weight > 0 ? weight : 0
    }

    /// The layout proper, for usable weights sorted heaviest first. Each row is laid along the shorter side of the
    /// space that is left and grows while that does not make its worst aspect ratio worse.
    ///
    /// `tail` is weight that is not laid out but keeps its share of `rect`: the space left over at the end. With a
    /// `minimumSide`, a row whose smallest rect would come out shorter than that drops weights from its light end
    /// until it fits; once a row cannot fit at all, the layout stops and the rest goes to the leftover space too.
    /// - Returns: Rects for the positive weights from the start of `weights` that were placed, and the leftover.
    static func layout(sortedWeights weights: [Double], tail: Double = 0, minimumSide: Double = 0,
                       in rect: CGRect) -> (rects: [CGRect], leftover: CGRect) {
        let rect = rect.standardized
        // The positive weights are a prefix.
        let count = weights.firstIndex { !($0 > 0) } ?? weights.count
        guard count > 0, rect.width > 0, rect.height > 0, (rect.width * rect.height).isFinite else {
            let origin = rect.isNull ? CGPoint.zero : rect.origin
            return ([], tail > 0 ? rect : CGRect(origin: origin, size: .zero))
        }

        // What is left to place from each index on, summed from the light end so a long tail is not lost to rounding.
        var remaining = Array(repeating: tail, count: count + 1)
        for index in (0..<count).reversed() {
            remaining[index] = remaining[index + 1] + weights[index]
        }

        var rects: [CGRect] = []
        rects.reserveCapacity(count)
        var minX = Double(rect.minX), minY = Double(rect.minY)
        let maxX = Double(rect.maxX), maxY = Double(rect.maxY)
        var start = 0
        while start < count {
            let width = maxX - minX, height = maxY - minY
            let side = min(width, height)
            guard side > 0 else { break } // rounding left no room
            let scale = width * height / remaining[start]
            let largest = weights[start] * scale

            var end = start + 1
            var rowWeight = weights[start]
            var worst = worstAspectRatio(area: largest, largest: largest, smallest: largest, side: side)
            while end < count {
                let candidate = worstAspectRatio(
                    area: (rowWeight + weights[end]) * scale, largest: largest, smallest: weights[end] * scale, side: side)
                if candidate > worst { break }
                worst = candidate
                rowWeight += weights[end]
                end += 1
            }

            if minimumSide > 0 {
                // Dropping the lightest rect makes the row thinner and the others longer.
                while end > start {
                    let thickness = rowWeight * scale / side
                    if thickness < minimumSide {
                        end = start // and shorter rows are thinner still
                    } else if weights[end - 1] * scale / thickness < minimumSide {
                        end -= 1
                        rowWeight -= weights[end]
                        continue
                    }
                    break
                }
                guard end > start else { break }
            }

            // The row is as thick as its share of what is left. The last row, and the last rect in each row, end
            // exactly at the edge, so rounding never leaves a gap.
            let isLastRow = end == count && tail == 0
            let share = isLastRow ? 1 : min(1, rowWeight / remaining[start])
            var placed = 0.0
            if width >= height { // a column on the left, filled top to bottom
                let rowMaxX = isLastRow ? maxX : minX + width * share
                var y = minY
                for index in start..<end {
                    placed += weights[index]
                    let nextY = index == end - 1 ? maxY : minY + height * (placed / rowWeight)
                    rects.append(CGRect(x: minX, y: y, width: rowMaxX - minX, height: nextY - y))
                    y = nextY
                }
                minX = rowMaxX
            } else { // a row along the top, filled left to right
                let rowMaxY = isLastRow ? maxY : minY + height * share
                var x = minX
                for index in start..<end {
                    placed += weights[index]
                    let nextX = index == end - 1 ? maxX : minX + width * (placed / rowWeight)
                    rects.append(CGRect(x: x, y: minY, width: nextX - x, height: rowMaxY - minY))
                    x = nextX
                }
                minY = rowMaxY
            }
            start = end
        }
        return (rects, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    /// The worst aspect ratio in a row of total `area` laid along `side`, given its largest and smallest area.
    private static func worstAspectRatio(area: Double, largest: Double, smallest: Double, side: Double) -> Double {
        let sideSquared = side * side, areaSquared = area * area
        return max(sideSquared * largest / areaSquared, areaSquared / (sideSquared * smallest))
    }
}
