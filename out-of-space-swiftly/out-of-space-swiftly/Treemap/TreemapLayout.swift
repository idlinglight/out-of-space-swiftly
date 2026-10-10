import CoreGraphics

/// One child as the caller describes it to `TreemapLayout`. Generic over the id so the layout needs no model type.
nonisolated struct TreemapItem<ID: Hashable & Sendable>: Sendable, Equatable {
    var id: ID
    /// Non-negative; negative and non-finite weights count as zero.
    var weight: Double
    /// Whether the layout may ask for this item's children.
    var isContainer: Bool
}

/// Geometry rules for `TreemapLayout`, in points.
nonisolated struct TreemapStyle: Sendable, Equatable {
    /// Inset on all four sides of a container, between its edge and its header and children.
    var padding: CGFloat = 2
    /// Height of the label band at the top of a container, inside the padding; 0 for none.
    var headerHeight: CGFloat = 16
    /// A container gets a header only if its padded rect is at least this wide and still has `minimumSide` below it.
    var minimumHeaderWidth: CGFloat = 48
    /// A container whose padded content is narrower than this is not subdivided. Children that would come out
    /// narrower are not tiles of their own; they go into their container's remainder.
    var minimumSide: CGFloat = 4
    /// Containers at this depth are not subdivided (the root is depth 0).
    var maximumDepth = Int.max
    /// Once subdividing a container would make more tiles than this, no further container is subdivided.
    var maximumTileCount: Int?

    /// The header band, if one fits, and the rect left for children inside a container's `rect`.
    func frame(of rect: CGRect) -> (header: CGRect?, content: CGRect) {
        let inner = rect.insetBy(dx: padding, dy: padding)
        let below = inner.height - headerHeight
        guard !inner.isNull, headerHeight > 0, inner.width >= minimumHeaderWidth, below > 0, below >= minimumSide else {
            return (nil, inner)
        }
        return (CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: headerHeight),
                CGRect(x: inner.minX, y: inner.minY + headerHeight, width: inner.width, height: below))
    }
}

/// One rectangle of a nested treemap.
nonisolated struct TreemapTile<ID: Hashable & Sendable>: Sendable, Equatable {
    /// The item's id; a remainder tile carries the id of the container whose children it stands for.
    var id: ID
    var rect: CGRect
    /// 0 for the root, 1 for its children, and so on.
    var depth: Int
    var weight: Double
    var kind: Kind
    /// Index of the parent in `TreemapLayout.tiles`; nil for the root.
    var parent: Int?
    /// Indices of the children in `TreemapLayout.tiles`; empty unless the tile was subdivided.
    var children: Range<Int> = 0..<0
    /// The label band of a subdivided container, when one fits.
    var header: CGRect?

    nonisolated enum Kind: Sendable, Equatable {
        case leaf
        /// A container whose children were laid out inside it.
        case subdivided
        /// A container drawn as one tile, its children not laid out.
        case cutOff(CutOffReason)
        /// The children of the parent too small to draw, as one tile in the space left after their siblings: how many
        /// there are, zero weights included. Its rect has no area when they all weigh nothing.
        case remainder(count: Int)
    }

    nonisolated enum CutOffReason: Sendable, Equatable {
        /// The padded content is narrower than `TreemapStyle.minimumSide`.
        case tooSmall
        case depthLimit
        case tileLimit
    }

    var isContainer: Bool {
        switch kind {
        case .subdivided, .cutOff: true
        case .leaf, .remainder: false
        }
    }
    var isSubdivided: Bool { kind == .subdivided }
    var isCutOff: Bool { if case .cutOff = kind { true } else { false } }
    var isRemainder: Bool { if case .remainder = kind { true } else { false } }
}

/// A nested squarified treemap, as a flat list of tiles. The caller describes the tree through a `children`
/// closure, so the layout depends on no model type; it asks only for the children of containers it subdivides.
nonisolated struct TreemapLayout<ID: Hashable & Sendable>: Sendable {
    /// Drawing order: the root first, every tile after its parent, siblings next to each other.
    let tiles: [TreemapTile<ID>]

    /// Lays out `root` in `rect`. The root fills `rect` without padding or header; its children fill the whole of it.
    /// Containers are subdivided breadth first, so a tile cap leaves out the deepest detail.
    init(root: TreemapItem<ID>, in rect: CGRect, style: TreemapStyle = TreemapStyle(),
         children: (ID) -> [TreemapItem<ID>]) {
        // Containers are appended as `.subdivided` and settled when the loop reaches them.
        var tiles = [TreemapTile(id: root.id, rect: rect.standardized, depth: 0, weight: root.weight,
                                 kind: root.isContainer ? .subdivided : .leaf, parent: nil)]
        var tileLimitReached = false
        var index = 0
        while index < tiles.count {
            defer { index += 1 }
            guard tiles[index].kind == .subdivided else { continue }
            let tile = tiles[index]
            let (header, content) = index == 0 ? (nil, tile.rect) : style.frame(of: tile.rect)
            guard tile.depth < style.maximumDepth else {
                tiles[index].kind = .cutOff(.depthLimit)
                continue
            }
            guard content.width > 0, content.height > 0,
                  content.width >= style.minimumSide, content.height >= style.minimumSide else {
                tiles[index].kind = .cutOff(.tooSmall)
                continue
            }
            guard !tileLimitReached else {
                tiles[index].kind = .cutOff(.tileLimit)
                continue
            }

            let items = children(tile.id)
            let placement = ChildPlacement(weights: items.map { $0.weight }, in: content, minimumSide: style.minimumSide)
            if let cap = style.maximumTileCount, tiles.count + placement.rects.count > cap {
                tiles[index].kind = .cutOff(.tileLimit)
                tileLimitReached = true
                continue
            }
            tiles[index].header = header
            tiles[index].children = tiles.count..<(tiles.count + placement.rects.count)
            for (child, rect) in placement.rects {
                if let child {
                    let item = items[child]
                    tiles.append(TreemapTile(id: item.id, rect: rect, depth: tile.depth + 1, weight: item.weight,
                                             kind: item.isContainer ? .subdivided : .leaf, parent: index))
                } else {
                    tiles.append(TreemapTile(id: tile.id, rect: rect, depth: tile.depth + 1,
                                             weight: placement.remainderWeight,
                                             kind: .remainder(count: placement.remainderCount), parent: index))
                }
            }
        }
        self.tiles = tiles
    }

    /// Index of the deepest tile containing `point`, nil outside the root. Edges are half-open as in
    /// `CGRect.contains`: a point on the edge two siblings share belongs to the right or lower one.
    func tileIndex(at point: CGPoint) -> Int? {
        // Children follow their parents and siblings do not overlap, so the last hit is the deepest. A spatial index
        // can replace this scan behind the same signature.
        tiles.lastIndex { $0.rect.contains(point) }
    }

    func tile(at point: CGPoint) -> TreemapTile<ID>? {
        tileIndex(at: point).map { tiles[$0] }
    }
}

/// Where a container's children go: those big enough to draw, heaviest first, then one remainder for the rest in
/// the space left at the end.
private nonisolated struct ChildPlacement {
    /// The child's index in the input, or nil for the remainder, with its rect.
    var rects: [(child: Int?, rect: CGRect)] = []
    var remainderWeight = 0.0
    var remainderCount = 0

    init(weights: [Double], in content: CGRect, minimumSide: CGFloat) {
        let weights = weights.map(SquarifiedLayout.usable)
        let total = weights.reduce(0, +)
        let area = Double(content.width * content.height)

        // A child smaller than a square of the minimum side can never be drawn: it goes straight into the
        // remainder, and only the others need sorting.
        let minimumWeight = total > 0 && area > 0 ? Double(minimumSide * minimumSide) * total / area : .infinity
        var candidates: [Int] = []
        for (index, weight) in weights.enumerated() {
            if weight > 0, weight >= minimumWeight {
                candidates.append(index)
            } else {
                remainderWeight += weight
                remainderCount += 1
            }
        }
        candidates = SquarifiedLayout.heaviestFirst(candidates, by: weights)

        let layout = SquarifiedLayout.layout(sortedWeights: candidates.map { weights[$0] }, tail: remainderWeight,
                                             minimumSide: Double(minimumSide), in: content)
        rects = zip(candidates, layout.rects).map { ($0, $1) }
        for index in candidates.dropFirst(layout.rects.count) {
            remainderWeight += weights[index]
            remainderCount += 1
        }
        if remainderCount > 0 {
            rects.append((nil, layout.leftover))
        }
    }
}
