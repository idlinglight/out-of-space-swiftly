import Foundation
import os

/// Keeping a scan current: file system events name the folders that changed; after a quiet moment each is
/// brought up to date in the background. Usually one level is enough (the folder is listed again, folders
/// below it that are still there keep what was found in them, new ones are scanned); when macOS says events
/// were lost, everything below the folder is scanned again.
extension ScanWindowModel {
    /// How long to wait after the last change, so a burst of changes costs one refresh.
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
        guard !pendingChanges.isEmpty, phase == .finished, refreshTask == nil else { return }
        debounceTask?.cancel()
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
            guard let id = Self.directory(for: change.path, in: tree, rootPath: target.path) else { continue }
            if change.deep {
                let result = await Scan(root: tree.url(of: id)).run()
                guard !Task.isCancelled, self.tree === tree, !result.wasCancelled else { return }
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
        var options = ScanOptions()
        options.descends = false
        options.includesDataVolume = false
        let listing = await Scan(root: url, options: options).run()
        guard !Task.isCancelled, self.tree === tree, !listing.wasCancelled else { return }

        var known: [String: UInt64] = [:]
        for child in tree.children(of: id) where tree.kind(of: child) == .directory {
            known[tree.name(of: child)] = tree.node(child).fileID
        }
        var subtrees: [String: ScanTree] = [:]
        let entries = listing.tree
        for child in entries.children(of: entries.root)
        where entries.kind(of: child) == .directory && !entries.flags(of: child).contains(.notEntered) {
            let name = entries.name(of: child)
            guard known[name] != entries.node(child).fileID else { continue }
            let result = await Scan(root: url.appendingPathComponent(name, isDirectory: true)).run()
            guard !Task.isCancelled, self.tree === tree, !result.wasCancelled else { return }
            subtrees[name] = result.tree
        }
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

    /// The tree's directory for a changed folder: the folder itself, or its nearest ancestor that the scan
    /// entered. For a scan of `/`, paths on the Data volume are mapped to where the tree shows them; the
    /// group of folders found only there is not refreshed as a whole (its listing would repeat everything).
    static func directory(for path: String, in tree: ScanTree, rootPath: String) -> NodeID? {
        var path = path
        let data = "System/Volumes/Data"
        if rootPath == "/", path == data || path.hasPrefix(data + "/") {
            let rest = String(path.dropFirst(data.count).drop { $0 == "/" })
            let first = rest.split(separator: "/").first.map(String.init) ?? ""
            let viaFirmlink = !first.isEmpty && tree.node(atRelativePath: first) != nil
            path = viaFirmlink ? rest : Scan.dataVolumeGroupName + (rest.isEmpty ? "" : "/" + rest)
        }
        var components = path.split(separator: "/").map(String.init)
        while true {
            if let id = tree.node(atRelativePath: components.joined(separator: "/")) {
                let kind = tree.kind(of: id)
                if kind == .group { return nil }
                if kind == .directory, !tree.flags(of: id).contains(.notEntered) { return id }
            }
            if components.isEmpty { return nil }
            components.removeLast()
        }
    }
}
