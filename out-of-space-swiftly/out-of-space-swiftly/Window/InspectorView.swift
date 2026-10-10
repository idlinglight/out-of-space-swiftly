import SwiftUI

/// Facts about the selection (or, with nothing selected, the zoom level) and what can be done with it.
struct InspectorView: View {
    let model: ScanWindowModel

    var body: some View {
        if let tree = model.tree {
            let id = model.selection ?? model.zoom
            InspectorContent(model: model, tree: tree, id: id, version: model.treeVersion,
                             zoomSize: tree.size(of: model.zoom))
        }
    }
}

private struct InspectorContent: View {
    let model: ScanWindowModel
    let tree: ScanTree
    let id: NodeID
    let version: Int
    let zoomSize: Int64

    var body: some View {
        let node = tree.node(id)
        let failure = tree.error(of: id).map { ScanFailure(errno: $0) }
        Form {
            Section {
                LabeledContent("Name") {
                    Text(tree.name(of: id)).textSelection(.enabled)
                }
                LabeledContent("Size", value: ByteCount.text(node.size))
                if id != model.zoom {
                    LabeledContent("Share", value: ByteCount.share(node.size, of: zoomSize))
                }
                if node.kind == .file, node.logicalSize != node.allocatedSize {
                    LabeledContent("Length", value: ByteCount.text(node.logicalSize))
                }
                if node.descendantCount > 0 {
                    LabeledContent("Items", value: Int(node.descendantCount).formatted())
                }
                LabeledContent("Where") {
                    Text(tree.path(of: id))
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .truncationMode(.middle)
                }
            }
            if id == tree.root, let usage = model.volumeUsage {
                VolumeComparison(usage: usage, scanned: node.size)
            }
            if let note = ItemSymbol.explanation(kind: node.kind, flags: node.flags, failure: failure) {
                Section {
                    Label(note, systemImage: ItemSymbol.name(kind: node.kind, flags: node.flags, failed: failure != nil))
                        .foregroundStyle(ItemSymbol.isWarning(flags: node.flags, failed: failure != nil) ? .orange : .secondary)
                }
            }
            Section {
                ItemActions(model: model, id: id)
            }
        }
        .formStyle(.grouped)
    }
}

/// What the volume uses beside what the scan found, with the difference named rather than hidden.
private struct VolumeComparison: View {
    let usage: ScanWindowModel.VolumeUsage
    let scanned: Int64

    var body: some View {
        Section("Compared with the volume") {
            LabeledContent("\(usage.name) uses", value: ByteCount.text(usage.used))
            LabeledContent("Found by the scan", value: ByteCount.text(scanned))
            if usage.used > scanned {
                LabeledContent("Not found", value: ByteCount.text(usage.used - scanned))
                Text("Folders that could not be read or were left out, local snapshots, and the file system's own data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ItemActions: View {
    let model: ScanWindowModel
    let id: NodeID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Show in Finder", systemImage: "folder") { model.revealInFinder(id) }
            if model.tree?.isContainer(id) == true, id != model.zoom {
                Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoom(into: id) }
            }
            Button("Copy Path", systemImage: "doc.on.doc") { model.copyPath(id) }
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.pendingTrash = id }
                .disabled(!model.canMoveToTrash(id))
        }
        .buttonStyle(.borderless)
    }
}

/// The context menu for an item, in the outline and the treemap.
struct ItemMenu: View {
    let model: ScanWindowModel
    let id: NodeID
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.tree?.isContainer(id) == true {
            Button("Zoom In") { model.zoom(into: id) }
            if let path = model.tree?.path(of: id) {
                // A window of its own scans the folder again, independently (ADR-0003).
                Button("Open in New Window") { openWindow(value: ScanTarget(path: path)) }
            }
        } else {
            Button("Open") { model.open(id) }
        }
        Button("Show in Finder") { model.revealInFinder(id) }
        Button("Copy Path") { model.copyPath(id) }
        Divider()
        Button("Move to Trash…", role: .destructive) { model.pendingTrash = id }
            .disabled(!model.canMoveToTrash(id))
    }
}
