import SwiftUI

/// A finished scan: the outline in the sidebar, the treemap, and the inspector for the selection.
struct ScanView: View {
    let model: ScanWindowModel
    let choose: (URL) -> Void
    #if DEBUG
    @State private var showsInspector = DebugAids.showsInspector
    #else
    @State private var showsInspector = true
    #endif

    var body: some View {
        NavigationSplitView {
            OutlineView(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 600)
        } detail: {
            VStack(spacing: 0) {
                ZoomPathBar(model: model)
                Divider()
                TreemapPanel(model: model)
                Divider()
                StatusBar(model: model, showsItem: !showsInspector)
            }
            .inspector(isPresented: $showsInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
            }
        }
        .toolbar {
            ScanToolbar(model: model, showsInspector: $showsInspector, choose: choose)
        }
        .confirmationDialog(trashQuestion, isPresented: isAskingToTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let id = model.pendingTrash { model.moveToTrash(id) }
                model.pendingTrash = nil
            }
            Button("Cancel", role: .cancel) { model.pendingTrash = nil }
        } message: {
            Text("It can be put back from the Trash until the Trash is emptied.")
        }
        .frame(minWidth: 900, minHeight: 540)
    }

    private var isAskingToTrash: Binding<Bool> {
        Binding { model.pendingTrash != nil } set: { if !$0 { model.pendingTrash = nil } }
    }

    private var trashQuestion: String {
        guard let id = model.pendingTrash, let tree = model.tree else { return "" }
        return "Move “\(tree.name(of: id))” (\(ByteCount.text(tree.size(of: id)))) to the Trash?"
    }
}

private struct ScanToolbar: ToolbarContent {
    let model: ScanWindowModel
    @Binding var showsInspector: Bool
    let choose: (URL) -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Zoom Out", systemImage: "chevron.up") { model.zoomOut() }
                .disabled(!model.canZoomOut)
                .help("Show the enclosing folder")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Scan Again", systemImage: "arrow.clockwise") { model.rescan() }
                .help("Scan this folder again")
            Button("Choose Folder", systemImage: "folder") { openPanel() }
                .help("Scan another folder in this window")
            Button("Inspector", systemImage: "sidebar.trailing") { showsInspector.toggle() }
                .help(showsInspector ? "Hide the inspector" : "Show the inspector")
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Scan"
        if panel.runModal() == .OK, let url = panel.url { choose(url) }
    }
}

/// The zoom level's ancestry, each part a button that zooms there.
private struct ZoomPathBar: View {
    let model: ScanWindowModel

    var body: some View {
        if let tree = model.tree {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tree.lineage(of: model.zoom), id: \.self) { id in
                        if id != tree.root {
                            Image(systemName: "chevron.compact.right")
                                .foregroundStyle(.tertiary)
                        }
                        Button(tree.name(of: id)) { model.zoom(into: id) }
                            .buttonStyle(.accessoryBar)
                            .fontWeight(id == model.zoom ? .semibold : .regular)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }
}

/// The scan's state. The selection and the item under the pointer have their places in the inspector; with the
/// inspector hidden, one of them shows here (the item under the pointer, or else the selection, marked as
/// in the inspector) on the left, with the scan's state kept on the right, so neither takes the other's place.
private struct StatusBar: View {
    let model: ScanWindowModel
    let showsItem: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsItem {
                if let tree = model.tree, let id = model.hovered ?? model.selection {
                    OutlineSwatch(isSelection: model.hovered == nil)
                    Text(tree.name(of: id)).fontWeight(.medium)
                    Text(ByteCount.text(tree.size(of: id))).monospacedDigit()
                    Text(ByteCount.share(tree.size(of: id), of: tree.size(of: model.zoom)))
                        .foregroundStyle(.secondary)
                    Text(tree.path(of: id))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 16)
                summary(includesDuration: false)
            } else {
                summary(includesDuration: true)
                Spacer(minLength: 0)
            }
            UpdatingIndicator(isRefreshing: model.isRefreshing)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    @ViewBuilder private func summary(includesDuration: Bool) -> some View {
        if let summary = model.lastScan {
            Text(summaryText(summary, includesDuration: includesDuration))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    private func summaryText(_ summary: ScanWindowModel.ScanSummary, includesDuration: Bool) -> String {
        var text = "\(summary.files.formatted()) files"
        if includesDuration {
            text += ", scanned in \(summary.duration.formatted(.units(allowed: [.minutes, .seconds], fractionalPart: .show(length: 1))))"
        }
        if summary.failures > 0 {
            text += ", \(summary.failures.formatted()) \(summary.failures == 1 ? "folder" : "folders") not readable"
        }
        if summary.wasCancelled { text += ", stopped early" }
        return text
    }
}

/// Says so while background updates run, once they have taken a moment: most are over long before, and an
/// indicator that blinks with each of them only distracts. Its place stays reserved.
private struct UpdatingIndicator: View {
    let isRefreshing: Bool
    @State private var isShown = false

    var body: some View {
        HStack(spacing: 6) {
            if isShown {
                ProgressView().controlSize(.small)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
            Text("Updating…").foregroundStyle(.secondary).opacity(isShown ? 1 : 0)
        }
        .accessibilityHidden(!isShown)
        .task(id: isRefreshing) {
            guard isRefreshing else {
                isShown = false
                return
            }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { isShown = true }
        }
    }
}
