import AppKit
import Observation
import os

/// What a window shows: one folder or volume to scan. It is the window's scene value, so windows come back
/// with their folder after a relaunch (ADR-0003).
nonisolated struct ScanTarget: Codable, Hashable, Sendable {
    var path: String

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var displayName: String {
        path == "/" ? (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "/"
            : FileManager.default.displayName(atPath: path)
    }
}

/// Everything one window knows about its scan: the tree, where the treemap is zoomed to, what is selected
/// and hovered. Each window has its own; nothing here is shared between windows (ADR-0003).
@MainActor @Observable
final class ScanWindowModel {
    enum Phase: Equatable {
        /// No folder chosen yet.
        case choosing
        case scanning
        case finished
    }

    private(set) var target: ScanTarget?
    private(set) var phase = Phase.choosing
    private(set) var progress = ScanProgress()
    private(set) var tree: ScanTree?
    /// Bumped whenever the tree changes in place (an item moved to the Trash), so drawings refresh.
    private(set) var treeVersion = 0
    private(set) var lastScan: ScanSummary?

    /// The node whose contents fill the treemap and the outline.
    private(set) var zoom: NodeID = 0
    var selection: NodeID?
    var hovered: NodeID?
    /// Something went wrong that the window should say, such as a failed move to the Trash.
    var problem: String?
    /// An item waiting for the user to confirm moving it to the Trash.
    var pendingTrash: NodeID?

    struct ScanSummary: Equatable {
        var duration: Duration
        var wasCancelled: Bool
        var files: Int
        var failures: Int
    }

    /// For a scan of a whole volume: what the volume says it uses, to set beside what the scan found.
    private(set) var volumeUsage: VolumeUsage?

    struct VolumeUsage: Equatable {
        var name: String
        var used: Int64
    }

    /// Folders changed on disk since the scan, rescanned in the background (see `+Refresh`).
    private(set) var isRefreshing = false

    @ObservationIgnored private var scan: Scan?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored var watchTask: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    /// Changed folders (relative to the root, "" for the root itself) waiting to be rescanned.
    @ObservationIgnored var pendingChanges: Set<String> = []

    var isScanning: Bool { phase == .scanning }

    /// The size of everything scanned; follows changes made in place (Trash, background rescans).
    var totalSize: Int64 {
        _ = treeVersion
        return tree.map { $0.size(of: $0.root) } ?? 0
    }

    // MARK: Scanning

    /// Scans `target`, replacing whatever the window showed.
    func start(_ target: ScanTarget) {
        cancel()
        stopWatching()
        self.target = target
        phase = .scanning
        progress = ScanProgress()
        selection = nil
        hovered = nil
        let scan = Scan(root: target.url)
        self.scan = scan
        scanTask = Task { [weak self] in
            let updates = Task { [weak self] in
                for await progress in scan.progress {
                    self?.progress = progress
                }
            }
            let result = await scan.run()
            updates.cancel()
            self?.finish(result, of: scan)
        }
    }

    func rescan() {
        guard let target else { return }
        start(target)
    }

    /// Stops a running scan; what was found so far stays.
    func cancel() {
        scan?.cancel()
    }

    private func finish(_ result: ScanResult, of finished: Scan) {
        guard finished === scan else { return }
        tree = result.tree
        treeVersion += 1
        zoom = result.tree.root
        lastScan = ScanSummary(duration: result.duration, wasCancelled: result.wasCancelled,
                               files: result.progress.files, failures: result.progress.failures)
        progress = result.progress
        phase = .finished
        scan = nil
        scanTask = nil
        if !result.wasCancelled, let target {
            watch(target)
            loadVolumeUsage(for: target)
        }
    }

    /// Looks up whether the scan root is a volume's root and, if so, how much that volume uses.
    private func loadVolumeUsage(for target: ScanTarget) {
        volumeUsage = nil
        Task { [weak self] in
            let usage = await Task.detached(priority: .utility) { () -> VolumeUsage? in
                guard let volume = try? Volumes.volume(containing: target.url),
                      volume.url.standardizedFileURL.path == target.url.standardizedFileURL.path else { return nil }
                return VolumeUsage(name: volume.name, used: volume.displayedUsedCapacity)
            }.value
            guard let self, self.target == target else { return }
            self.volumeUsage = usage
        }
    }

    /// Ends everything running for this window; called when it closes.
    func close() {
        cancel()
        stopWatching()
    }

    func stopWatching() {
        watchTask?.cancel()
        refreshTask?.cancel()
        watchTask = nil
        refreshTask = nil
        pendingChanges = []
        isRefreshing = false
    }

    /// Puts a tree from a background rescan in place, keeping zoom and selection where their paths still exist.
    func replaceTree(_ apply: (ScanTree) -> Void) {
        guard let tree else { return }
        let zoomPath = tree.relativePath(of: zoom)
        let selectionPath = selection.map { tree.relativePath(of: $0) }
        apply(tree)
        treeVersion += 1
        zoom = Self.nearest(zoomPath, in: tree)
        selection = selectionPath.flatMap { tree.node(atRelativePath: $0) }
        hovered = nil
    }

    func setRefreshing(_ refreshing: Bool) {
        isRefreshing = refreshing
    }

    func setTree(_ newTree: ScanTree) {
        let zoomPath = tree.map { $0.relativePath(of: zoom) } ?? ""
        let selectionPath = tree.flatMap { tree in selection.map { tree.relativePath(of: $0) } }
        tree = newTree
        treeVersion += 1
        zoom = Self.nearest(zoomPath, in: newTree)
        selection = selectionPath.flatMap { newTree.node(atRelativePath: $0) }
        hovered = nil
    }

    /// The node at `path`, or its nearest ancestor that is still a container.
    static func nearest(_ path: String, in tree: ScanTree) -> NodeID {
        var components = path.split(separator: "/").map(String.init)
        while !components.isEmpty {
            if let id = tree.node(atRelativePath: components.joined(separator: "/")), tree.isContainer(id) { return id }
            components.removeLast()
        }
        return tree.root
    }

    // MARK: Zooming

    var canZoomOut: Bool { tree?.parent(of: zoom) != nil }

    /// Zooms into a container: it fills the treemap.
    func zoom(into id: NodeID) {
        guard let tree, tree.isContainer(id) else { return }
        zoom = id
        if let selection, !tree.lineage(of: selection).contains(id) { self.selection = nil }
    }

    func zoomOut() {
        guard let tree, let parent = tree.parent(of: zoom) else { return }
        let previous = zoom
        zoom = parent
        selection = previous
    }

    /// The deepest container on the way from the zoom level to `id` that is a direct child of the zoom.
    func zoomTowards(_ id: NodeID) {
        guard let tree else { return }
        let lineage = tree.lineage(of: id)
        guard let index = lineage.firstIndex(of: zoom), index + 1 < lineage.count else { return }
        zoom(into: lineage[index + 1])
    }

    // MARK: Acting on items

    func revealInFinder(_ id: NodeID) {
        guard let tree else { return }
        NSWorkspace.shared.activateFileViewerSelecting([tree.url(of: id)])
    }

    func open(_ id: NodeID) {
        guard let tree else { return }
        NSWorkspace.shared.open(tree.url(of: id))
    }

    func copyPath(_ id: NodeID) {
        guard let tree else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tree.path(of: id), forType: .string)
    }

    /// Whether `id` may be moved to the Trash from here: not the scan root, and nothing the scanner made up.
    func canMoveToTrash(_ id: NodeID) -> Bool {
        guard let tree, id != tree.root else { return false }
        return tree.kind(of: id) != .group && !tree.flags(of: id).contains(.removed)
    }

    /// Moves the item to the Trash (the caller has asked for confirmation) and takes it out of the totals.
    func moveToTrash(_ id: NodeID) {
        guard let tree, canMoveToTrash(id) else { return }
        do {
            try FileManager.default.trashItem(at: tree.url(of: id), resultingItemURL: nil)
            Log.app.notice("Moved to the Trash: \(tree.path(of: id), privacy: .private)")
            tree.remove(id)
            treeVersion += 1
            if let selection, tree.lineage(of: selection).contains(id) { self.selection = nil }
            hovered = nil
            if tree.lineage(of: zoom).contains(id) { zoom = tree.parent(of: id) ?? tree.root }
        } catch {
            problem = "“\(tree.name(of: id))” could not be moved to the Trash: \(error.localizedDescription)"
        }
    }
}
