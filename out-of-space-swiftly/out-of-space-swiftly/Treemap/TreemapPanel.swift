import SwiftUI

/// The treemap of the zoom level: hover to see an item, click to select, double-click to zoom in one level.
struct TreemapPanel: View {
    let model: ScanWindowModel

    var body: some View {
        GeometryReader { geometry in
            if let tree = model.tree {
                TreemapContent(model: model, tree: tree, key: TreemapDrawing.Key(
                    version: model.treeVersion, zoom: model.zoom, size: geometry.size))
            }
        }
        .background(.background)
    }
}

/// Holds the drawing for the current zoom level and size, and turns pointer events into model changes.
private struct TreemapContent: View {
    let model: ScanWindowModel
    let tree: ScanTree
    let key: TreemapDrawing.Key
    @State private var drawing: TreemapDrawing?
    @State private var relayout: Task<Void, Never>?
    /// The tile under the pointer, which may be a "smaller items" tile (that has no node of its own).
    @State private var hoveredTile: Int?

    var body: some View {
        ZStack {
            if let drawing {
                TreemapTiles(drawing: drawing)
                if let drawing = current {
                    TreemapHighlight(drawing: drawing, tree: tree, hoveredTile: hoveredTile, selection: model.selection)
                }
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let index = tile(at: location)
                if hoveredTile != index { hoveredTile = index }
                let id = index.flatMap { current?.layout.tiles[$0].id }
                if model.hovered != id { model.hovered = id }
            case .ended:
                hoveredTile = nil
                model.hovered = nil
            }
        }
        .gesture(SpatialTapGesture(count: 1).onEnded { value in
            model.selection = node(at: value.location)
        })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
            guard let id = node(at: value.location) else { return }
            model.zoomTowards(id)
        })
        .contextMenu {
            if let id = model.hovered ?? model.selection {
                ItemMenu(model: model, id: id)
            }
        }
        .onChange(of: key, initial: true) { _, key in
            relayout?.cancel()
            guard let drawing, drawing.key.version == key.version, drawing.key.zoom == key.zoom else {
                drawing = TreemapDrawing(tree: tree, key: key)
                return
            }
            // While the window is being resized, the last drawing is shown scaled; the layout is redone
            // once the size has settled.
            relayout = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self.drawing = TreemapDrawing(tree: tree, key: key)
            }
        }
    }

    /// The drawing, if it was made from the tree as it is now. Updates can renumber nodes; until the drawing
    /// is redone, its IDs would point to the wrong items. A drawing for another size (during a resize) is fine.
    private var current: TreemapDrawing? {
        guard let drawing, drawing.key.version == key.version, drawing.key.zoom == key.zoom else { return nil }
        return drawing
    }

    private func tile(at location: CGPoint) -> Int? {
        guard let drawing = current else { return nil }
        let point = CGPoint(x: location.x * drawing.key.size.width / max(key.size.width, 1),
                            y: location.y * drawing.key.size.height / max(key.size.height, 1))
        guard let index = drawing.layout.tileIndex(at: point), index > 0 else { return nil }
        return index
    }

    private func node(at location: CGPoint) -> NodeID? {
        tile(at: location).flatMap { current?.layout.tiles[$0].id }
    }
}

/// The tiles, drawn once per layout; hover and selection are drawn on top by `TreemapHighlight`.
private struct TreemapTiles: View, Equatable {
    let drawing: TreemapDrawing

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            drawing.scale(&context, to: size)
            for (index, tile) in drawing.layout.tiles.enumerated() where index > 0 {
                let style = drawing.styles[index]
                let rect = tile.rect
                guard rect.width >= 1, rect.height >= 1 else { continue }
                // Rounded corners only where they read as corners; on tiny tiles they turn into dots.
                let radius = min(rect.width, rect.height) >= 12 ? 3.0 : 0
                let shape = Path(roundedRect: rect, cornerRadius: radius)
                context.fill(shape, with: .color(style.fill))
                if tile.isSubdivided {
                    context.stroke(shape, with: .color(.primary.opacity(0.08)), lineWidth: 0.5)
                }
                if let header = tile.header {
                    draw(label: style.label, detail: style.detail, in: header.insetBy(dx: 4, dy: 0),
                         font: .caption.weight(.medium), context: &context)
                } else if !tile.isSubdivided, style.showsLabel, rect.width > 56, rect.height > 18 {
                    // A subdivided folder without room for a header gets no label: its children fill it.
                    let band = CGRect(x: rect.minX + 4, y: rect.minY + 2, width: rect.width - 8, height: 14)
                    draw(label: style.label, detail: rect.height > 34 ? style.detail : nil, in: band,
                         font: .caption2, context: &context)
                }
            }
        }
    }

    private func draw(label: String, detail: String?, in rect: CGRect, font: Font, context: inout GraphicsContext) {
        let text = if let detail, rect.width > 120 {
            Text("\(Text(label).foregroundStyle(.primary))  \(Text(detail).foregroundStyle(.secondary))").font(font)
        } else {
            Text(label).font(font).foregroundStyle(.primary)
        }
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.draw(text, in: rect)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.drawing.key == rhs.drawing.key
    }
}

/// Outlines for the tile under the pointer and for the selected item: solid around the item's own tile, dashed
/// around the tile standing in for an item too small to have one.
private struct TreemapHighlight: View {
    let drawing: TreemapDrawing
    let tree: ScanTree
    let hoveredTile: Int?
    let selection: NodeID?

    var body: some View {
        Canvas { context, size in
            // The rects are scaled, not the context, so strokes and dashes keep their shape during a resize.
            let selected = selection.flatMap { drawing.outline(for: $0, in: tree) }
            if let hoveredTile, drawing.layout.tiles[hoveredTile].rect != selected?.rect {
                let rect = drawing.scaled(drawing.layout.tiles[hoveredTile].rect, to: size)
                context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3),
                               with: .color(.primary.opacity(0.7)), lineWidth: 1)
            }
            if let selected {
                let rect = Self.visible(drawing.scaled(selected.rect, to: size), within: CGRect(origin: .zero, size: size))
                context.stroke(Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 3),
                               with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 2, dash: selected.isExact ? [] : [5, 3]))
            }
        }
        .allowsHitTesting(false)
    }

    /// A tile a few points small still gets an outline one can see, centered on it and kept inside the view.
    private static func visible(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        let side: CGFloat = 12
        var rect = rect.insetBy(dx: min(0, (rect.width - side) / 2), dy: min(0, (rect.height - side) / 2))
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect
    }
}

/// A laid-out zoom level and how each tile looks.
struct TreemapDrawing {
    struct Key: Equatable {
        var version: Int
        var zoom: NodeID
        var size: CGSize
    }

    struct TileStyle {
        var fill: Color
        var label: String
        var detail: String?
        var showsLabel: Bool
    }

    let key: Key
    let layout: TreemapLayout<NodeID>
    let styles: [TileStyle]
    /// The first tile of each node; remainder tiles carry their container's id and are not listed. Folders
    /// folded into a chain point to the chain's tile.
    let tileIndex: [NodeID: Int]
    /// The "smaller items" tile of each folder that has one, by the folder's id.
    let remainderIndex: [NodeID: Int]

    /// A rect of the layout where it shows on a canvas of `size` (the same unless a resize is under way).
    func scaled(_ rect: CGRect, to size: CGSize) -> CGRect {
        guard size != key.size, key.size.width > 0, key.size.height > 0 else { return rect }
        let (x, y) = (size.width / key.size.width, size.height / key.size.height)
        return CGRect(x: rect.minX * x, y: rect.minY * y, width: rect.width * x, height: rect.height * y)
    }

    /// Fits the drawing to the canvas while the canvas is being resized and the layout not yet redone.
    func scale(_ context: inout GraphicsContext, to size: CGSize) {
        guard size != key.size, key.size.width > 0, key.size.height > 0 else { return }
        context.scaleBy(x: size.width / key.size.width, y: size.height / key.size.height)
    }

    static let style = TreemapStyle(padding: 3, headerHeight: 17, minimumHeaderWidth: 60, minimumSide: 4,
                                    maximumTileCount: 40_000)

    init(tree: ScanTree, key: Key) {
        self.key = key
        let root = TreemapItem(id: key.zoom, weight: Double(tree.size(of: key.zoom)), isContainer: tree.isContainer(key.zoom))
        let layout = TreemapLayout(root: root, in: CGRect(origin: .zero, size: key.size), style: Self.style) { id in
            tree.children(of: id).map { child in
                let shown = Self.endOfChain(from: child, in: tree)
                return TreemapItem(id: shown, weight: Double(tree.size(of: shown)), isContainer: tree.isContainer(shown))
            }
        }
        var index: [NodeID: Int] = [:]
        var remainders: [NodeID: Int] = [:]
        let styles = layout.tiles.enumerated().map { offset, tile in
            if case .remainder(let count) = tile.kind {
                remainders[tile.id] = offset
                return TileStyle(fill: TreemapPalette.remainder, label: "\(count.formatted()) smaller items",
                                 detail: ByteCount.text(Int64(tile.weight)), showsLabel: true)
            }
            if index[tile.id] == nil { index[tile.id] = offset }
            var name = tree.name(of: tile.id)
            if offset > 0, let parent = tile.parent {
                // A chain of single folders shows as one tile: "local › texlive › 2026basic".
                let chain = Self.chain(endingAt: tile.id, below: layout.tiles[parent].id, in: tree)
                if chain.count > 1 {
                    name = chain.map { tree.name(of: $0) }.joined(separator: " › ")
                    for member in chain where index[member] == nil { index[member] = offset }
                }
            }
            let fill = tile.isContainer ? TreemapPalette.container(depth: tile.depth, subdivided: tile.isSubdivided)
                : TreemapPalette.color(forFileNamed: tree.name(of: tile.id), kind: tree.kind(of: tile.id))
            return TileStyle(fill: fill, label: name, detail: ByteCount.text(tree.size(of: tile.id)), showsLabel: true)
        }
        self.layout = layout
        self.styles = styles
        tileIndex = index
        remainderIndex = remainders
    }

    /// Where to outline an item: its own tile (exact), or else the tile standing in for it, which is the
    /// "smaller items" tile it went into or a folder drawn as one block around it. Nil outside the zoom level,
    /// and for an item with no area anywhere (the whole view would be no help).
    func outline(for id: NodeID, in tree: ScanTree) -> (rect: CGRect, isExact: Bool)? {
        var current = id
        while true {
            if let index = tileIndex[current] {
                if index == 0, current != id { return nil }
                return (layout.tiles[index].rect, current == id)
            }
            guard let parent = tree.parent(of: current) else { return nil }
            if let index = remainderIndex[parent], !layout.tiles[index].rect.isEmpty {
                return (layout.tiles[index].rect, false)
            }
            current = parent
        }
    }

    /// Follows folders that hold nothing but one folder, so the treemap spends no header on each of them.
    static func endOfChain(from id: NodeID, in tree: ScanTree) -> NodeID {
        var current = id
        while tree.isContainer(current) {
            let children = tree.children(of: current)
            guard children.count == 1, let only = children.first, tree.isContainer(only) else { break }
            current = only
        }
        return current
    }

    /// The folders from just below `ancestor` down to `id`.
    static func chain(endingAt id: NodeID, below ancestor: NodeID, in tree: ScanTree) -> [NodeID] {
        let lineage = tree.lineage(of: id)
        guard let start = lineage.firstIndex(of: ancestor) else { return [id] }
        return Array(lineage[(start + 1)...])
    }
}
