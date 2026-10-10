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

    var body: some View {
        ZStack {
            if let drawing {
                TreemapTiles(drawing: drawing)
                TreemapHighlight(drawing: drawing, tree: tree, hovered: model.hovered, selection: model.selection)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let id = node(at: location)
                if model.hovered != id { model.hovered = id }
            case .ended:
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

    private func node(at location: CGPoint) -> NodeID? {
        guard let drawing else { return nil }
        let point = CGPoint(x: location.x * drawing.key.size.width / max(key.size.width, 1),
                            y: location.y * drawing.key.size.height / max(key.size.height, 1))
        guard let index = drawing.layout.tileIndex(at: point), index > 0 else { return nil }
        return drawing.layout.tiles[index].id
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

/// Outlines for the hovered and the selected item (or the nearest tile that stands for it).
private struct TreemapHighlight: View {
    let drawing: TreemapDrawing
    let tree: ScanTree
    let hovered: NodeID?
    let selection: NodeID?

    var body: some View {
        Canvas { context, size in
            drawing.scale(&context, to: size)
            if let rect = rect(for: hovered), hovered != selection {
                context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3),
                               with: .color(.primary.opacity(0.7)), lineWidth: 1)
            }
            if let rect = rect(for: selection) {
                context.stroke(Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 3),
                               with: .color(.accentColor), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func rect(for id: NodeID?) -> CGRect? {
        guard let id else { return nil }
        for ancestor in tree.lineage(of: id).reversed() {
            if let index = drawing.tileIndex[ancestor] { return drawing.layout.tiles[index].rect }
        }
        return nil
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
        let styles = layout.tiles.enumerated().map { offset, tile in
            if case .remainder(let count) = tile.kind {
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
