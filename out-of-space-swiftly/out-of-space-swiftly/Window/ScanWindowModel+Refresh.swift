import Foundation
import os

/// Keeping a scan current: file system events name the folders that changed; after a quiet moment each is
/// brought up to date in the background. Usually one level is enough (the folder is listed again, folders
/// below it that are still there keep what was found in them, new ones are scanned); when macOS says events
/// were lost, everything below the folder is scanned again.
extension ScanWindowModel {
    /// How long to wait after the first change before refreshing, so a burst of changes costs one refresh.
    /// Measured from the first change, not the last: a folder that never stops changing is still refreshed.
    static let refreshDelay: Duration = .seconds(2)

    func watch(_ target: ScanTarget) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            let events: FileSystemEvents
            do {
                events = try FileSystemEvents.watch(target.url)
            } catch {
                Log.app.error("Not watching \(target.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                return
            }
            for await batch in events.changes {
                guard let self else { return }
                for change in batch {
                    guard let path = events.relativePath(of: change.path) else { continue }
                    let deep = change.flags.contains(.mustScanSubdirectories)
                    self.pendingChanges[path] = (self.pendingChanges[path] ?? false) || deep
                }
                self.refreshIfPending()
            }
        }
    }

    /// Starts a refresh after a quiet moment, unless the scan or a refresh is still running; both call
    /// back here when they end.
    func refreshIfPending() {
        guard !pendingChanges.isEmpty, phase == .finished, refreshTask == nil, debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDelay)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.refreshTask = Task { [weak self] in
                await self?.refreshPending()
                guard let self, !Task.isCancelled else { return }
                self.refreshTask = nil
                self.refreshIfPending()
            }
        }
    }

    private func refreshPending() async {
        guard let tree, let target else { return }
        let changes = Self.coalesce(pendingChanges)
        pendingChanges = [:]
        setRefreshing(true)
        defer { setRefreshing(false) }
        for change in changes {
            guard !Task.isCancelled, self.tree === tree else { return }
            let id: NodeID
            switch Self.refreshTarget(for: change.path, in: tree, rootPath: target.path) {
            case .directory(let directory):
                id = directory
            case .unseen:
                continue
            case .unmapped:
                // Lost events somewhere the tree cannot point to (the Data volume of `/` as a whole): only a
                // full scan is sure to catch up.
                guard change.deep else { continue }
                id = tree.root
            }
            if change.deep {
                let path = tree.relativePath(of: id)
                let result = await Scan(root: tree.url(of: id), options: scanOptions).run()
                guard !Task.isCancelled, self.tree === tree, !result.wasCancelled else { return }
                // The folder may have gone to the Trash, or its ID changed, while it was being scanned.
                guard tree.node(atRelativePath: path) == id else { continue }
                updateTree { current in
                    guard id != current.root else { return result.tree }
                    current.graft(result.tree, at: id)
                    return current
                }
            } else {
                await refreshOneLevel(id, in: tree)
            }
        }
    }

    /// Lists the folder again and scans only the folders in it that are new.
    private func refreshOneLevel(_ id: NodeID, in tree: ScanTree) async {
        let url = tree.url(of: id)
        let path = tree.relativePath(of: id)
        var options = scanOptions
        options.descends = false
        options.includesDataVolume = false
        let listing = await Scan(root: url, options: options).run()
        guard !Task.isCancelled, self.tree === tree, !listing.wasCancelled else { return }
        // Busy folders are often changed back and forth, or rewritten as they were. Leaving the tree alone
        // then spares the window a new layout.
        guard !tree.hasSameEntries(id, as: listing.tree) else { return }

        var known: [String: NodeID] = [:]
        for child in tree.children(of: id) { known[tree.name(of: child)] = child }
        var subtrees: [String: ScanTree] = [:]
        let entries = listing.tree
        for child in entries.children(of: entries.root)
        where entries.kind(of: child) == .directory && !entries.flags(of: child).contains(.notEntered) {
            let name = entries.name(of: child)
            if let previous = known[name], tree.keepsSubtree(of: previous, for: entries.node(child)) { continue }
            let result = await Scan(root: url.appendingPathComponent(name, isDirectory: true), options: scanOptions).run()
            guard !Task.isCancelled, self.tree === tree, !result.wasCancelled else { return }
            subtrees[name] = result.tree
        }
        // The folder may have gone to the Trash, or its ID changed, while it was being listed.
        guard tree.node(atRelativePath: path) == id else { return }
        updateTree { current in
            current.refresh(id, listing: entries, subtrees: subtrees)
            return current
        }
    }

    /// The changes in an order that refreshes a folder before the folders inside it, without the ones a
    /// deep rescan above them covers anyway.
    static func coalesce(_ changes: [String: Bool]) -> [(path: String, deep: Bool)] {
        let deepPaths = changes.filter(\.value).map(\.key)
        return changes.sorted { $0.key < $1.key }
            .filter { path, _ in
                !deepPaths.contains { deep in deep != path && (deep.isEmpty || path.hasPrefix(deep + "/")) }
            }
            .map { (path: $0.key, deep: $0.value) }
    }

    /// What to bring up to date for a changed folder.
    enum RefreshTarget: Equatable {
        /// List this directory again: the changed folder itself, or its nearest ancestor in the tree.
        case directory(NodeID)
        /// In or inside a folder the scan left out, or inside one it could not open, so nothing the window
        /// shows can have changed. A folder that appears or goes away is reported for the folder that holds it.
        case unseen
        /// Somewhere the tree cannot point to: the group of folders found only on the Data volume, as a whole.
        case unmapped
    }

    /// Where a changed folder is in the tree. For a scan of `/`, paths on the Data volume are mapped to where
    /// the tree shows them; the group of folders found only there is not refreshed as a whole (its listing
    /// would repeat everything).
    static func refreshTarget(for path: String, in tree: ScanTree, rootPath: String) -> RefreshTarget {
        var path = path
        let data = "System/Volumes/Data"
        if rootPath == "/", path == data || path.hasPrefix(data + "/") {
            let rest = String(path.dropFirst(data.count).drop { $0 == "/" })
            let first = rest.split(separator: "/").first.map(String.init) ?? ""
            let viaFirmlink = !first.isEmpty && tree.node(atRelativePath: first) != nil
            path = viaFirmlink ? rest : Scan.dataVolumeGroupName + (rest.isEmpty ? "" : "/" + rest)
        }
        var components = path.split(separator: "/").map(String.init)
        let depth = components.count
        while true {
            if let id = tree.node(atRelativePath: components.joined(separator: "/")) {
                switch tree.kind(of: id) {
                case .group:
                    return .unmapped
                case .directory:
                    let flags = tree.flags(of: id)
                    // A cloud-only folder that gets downloaded is found by listing the folder that holds it.
                    if flags.contains(.dataless) { break }
                    // Left out on purpose: another app's container, a folder counted under another path.
                    if flags.contains(.notEntered) { return .unseen }
                    // Inside a folder that could not be opened, nothing can be seen. The folder itself is listed
                    // again: its permissions may have changed.
                    if components.count < depth, couldNotOpen(id, in: tree) { return .unseen }
                    return .directory(id)
                default:
                    break
                }
            }
            if components.isEmpty { return .unmapped }
            components.removeLast()
        }
    }

    /// A folder the scan could not open for lack of permission.
    private static func couldNotOpen(_ id: NodeID, in tree: ScanTree) -> Bool {
        guard tree.node(id).childCount == 0, let code = tree.error(of: id) else { return false }
        return [.noPermission, .protectedByMacOS].contains(ScanFailure(errno: code))
    }
}
