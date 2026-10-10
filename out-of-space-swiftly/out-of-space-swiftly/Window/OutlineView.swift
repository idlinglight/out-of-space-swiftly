import SwiftUI

/// The zoom level's contents as a sortable outline; shares its selection with the treemap.
struct OutlineView: View {
    let model: ScanWindowModel
    @State private var sortOrder = [KeyPathComparator(\OutlineRow.size, order: .reverse)]

    var body: some View {
        if let tree = model.tree {
            OutlineTable(tree: tree, version: model.treeVersion, zoom: model.zoom,
                         selection: Binding { model.selection } set: { model.selection = $0 },
                         sortOrder: $sortOrder)
                .contextMenu(forSelectionType: NodeID.self) { ids in
                    if let id = ids.first { ItemMenu(model: model, id: id) }
                } primaryAction: { ids in
                    guard let id = ids.first else { return }
                    tree.isContainer(id) ? model.zoom(into: id) : model.open(id)
                }
        }
    }
}

/// The table itself; reads only what it shows, so hovering in the treemap does not redraw it.
private struct OutlineTable: View {
    let tree: ScanTree
    let version: Int
    let zoom: NodeID
    @Binding var selection: NodeID?
    @Binding var sortOrder: [KeyPathComparator<OutlineRow>]

    var body: some View {
        let order = OutlineRow.Order(sortOrder.first)
        let rows = OutlineRow.rows(of: zoom, in: tree, order: order, version: version)
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                OutlineName(row: row)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Size", value: \.size) { row in
                Text(row.kind == .file || row.kind == .directory || row.kind == .group ? ByteCount.text(row.size) : "–")
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 72)
            .alignment(.trailing)
            TableColumn("Items", value: \.items) { row in
                Text(row.items > 0 ? row.items.formatted() : "").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 52)
            .alignment(.trailing)
        }
    }
}

/// One row: a node of the tree, with its children made only when the row is expanded.
nonisolated struct OutlineRow: Identifiable, Hashable, Sendable {
    enum Order: Hashable {
        case sizeDescending, sizeAscending, nameAscending, nameDescending, itemsDescending, itemsAscending

        init(_ comparator: KeyPathComparator<OutlineRow>?) {
            let ascending = comparator?.order == .forward
            switch comparator?.keyPath {
            case \OutlineRow.name: self = ascending ? .nameAscending : .nameDescending
            case \OutlineRow.items: self = ascending ? .itemsAscending : .itemsDescending
            default: self = ascending ? .sizeAscending : .sizeDescending
            }
        }
    }

    let id: NodeID
    let name: String
    let size: Int64
    let items: Int
    let kind: ScanTree.Kind
    let flags: ScanTree.Flags
    let failure: ScanFailure?
    private let tree: ScanTree
    private let order: Order
    private let version: Int

    static func rows(of parent: NodeID, in tree: ScanTree, order: Order, version: Int) -> [OutlineRow] {
        let rows = tree.children(of: parent).map { OutlineRow(id: $0, tree: tree, order: order, version: version) }
        switch order {
        case .sizeDescending: return rows
        case .sizeAscending: return rows.reversed()
        case .nameAscending: return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending: return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .itemsDescending: return rows.sorted { $0.items > $1.items }
        case .itemsAscending: return rows.sorted { $0.items < $1.items }
        }
    }

    private init(id: NodeID, tree: ScanTree, order: Order, version: Int) {
        let node = tree.node(id)
        self.id = id
        name = tree.name(of: id)
        size = node.size
        items = Int(node.descendantCount)
        kind = node.kind
        flags = node.flags
        failure = tree.error(of: id).map { ScanFailure(errno: $0) }
        self.tree = tree
        self.order = order
        self.version = version
    }

    /// nil for leaves, so the table shows no disclosure triangle.
    var children: [OutlineRow]? {
        tree.isContainer(id) ? Self.rows(of: id, in: tree, order: order, version: version) : nil
    }

    static func == (lhs: OutlineRow, rhs: OutlineRow) -> Bool {
        lhs.id == rhs.id && lhs.version == rhs.version && lhs.order == rhs.order && lhs.size == rhs.size
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct OutlineName: View {
    let row: OutlineRow

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ItemSymbol.name(kind: row.kind, flags: row.flags, failed: row.failure != nil))
                .foregroundStyle(ItemSymbol.isWarning(flags: row.flags, failed: row.failure != nil) ? .orange : .secondary)
                .frame(width: 16)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(ItemSymbol.explanation(kind: row.kind, flags: row.flags, failure: row.failure) ?? row.name)
    }
}

/// How an item is pictured and explained wherever it is listed.
enum ItemSymbol {
    static func name(kind: ScanTree.Kind, flags: ScanTree.Flags, failed: Bool) -> String {
        if flags.contains(.protected) { return "lock.shield" }
        if failed { return "exclamationmark.triangle" }
        if flags.contains(.dataless) { return "icloud" }
        switch kind {
        case .file: return "doc"
        case .directory: return "folder"
        case .symlink: return "arrow.turn.up.right"
        case .other: return "questionmark.square.dashed"
        case .mountPoint: return "externaldrive"
        case .automount: return "network"
        case .group: return "square.stack.3d.up"
        }
    }

    static func isWarning(flags: ScanTree.Flags, failed: Bool) -> Bool {
        failed || flags.contains(.protected) || flags.contains(.slow)
    }

    /// Why an item looks the way it does, or nil if there is nothing to say.
    static func explanation(kind: ScanTree.Kind, flags: ScanTree.Flags, failure: ScanFailure?) -> String? {
        if flags.contains(.protected) {
            return "Not scanned: macOS protects other apps' data here, and reading it can stall."
        }
        if let failure { return "Not readable: \(failure.summary)." }
        if flags.contains(.dataless) { return "In the cloud only; not downloaded, so not counted." }
        if flags.contains(.alreadyCounted) { return "Counted already under another path." }
        if flags.contains(.duplicate) { return "Shares its storage with an item counted elsewhere, so it adds nothing here." }
        switch kind {
        case .mountPoint: return "Another volume is mounted here; not included."
        case .automount: return "A network location that is mounted on demand; not included."
        case .group: return "Folders that exist only on the Data volume."
        case .symlink: return "A symbolic link; what it points to is not counted here."
        default: break
        }
        if flags.contains(.slow) { return "Reading this folder took unusually long." }
        if flags.contains(.mayShareBlocks) { return "May share part of its storage with a copy of it (a clone)." }
        return nil
    }
}
