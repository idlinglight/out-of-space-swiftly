import Foundation
import os

/// Keeping a finished scan current: file system events name the folders that changed; after a quiet
/// moment those folders are rescanned in the background and grafted into the tree.
extension ScanWindowModel {
    /// How long to wait after the last change before rescanning, so a burst of changes costs one rescan.
    static let refreshDelay: Duration = .seconds(2)

    func watch(_ target: ScanTarget) {
        stopWatching()
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
                let paths = batch.compactMap { events.relativePath(of: $0.path) }
                guard !paths.isEmpty else { continue }
                self.pendingChanges.formUnion(paths)
                self.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDelay)
            guard !Task.isCancelled, let self else { return }
            await self.refreshPending()
        }
    }

    /// Rescans the changed folders, each once: a folder whose ancestor also changed is covered by it.
    private func refreshPending() async {
        guard phase == .finished, let tree, let target else { return }
        let paths = Self.outermost(pendingChanges)
        pendingChanges = []
        setRefreshing(true)
        defer { setRefreshing(false) }

        if paths.contains("") {
            let result = await Scan(root: target.url).run()
            guard !Task.isCancelled, self.tree === tree, !result.wasCancelled else { return }
            setTree(result.tree)
            return
        }
        for path in paths {
            guard !Task.isCancelled, self.tree === tree else { return }
            let id = Self.nearest(path, in: tree)
            if id == tree.root {
                let result = await Scan(root: target.url).run()
                guard !Task.isCancelled, self.tree === tree, !result.wasCancelled else { return }
                setTree(result.tree)
                return
            }
            let result = await Scan(root: tree.url(of: id)).run()
            guard !Task.isCancelled, self.tree === tree, !result.wasCancelled else { return }
            replaceTree { $0.graft(result.tree, at: id) }
        }
    }

    /// The paths not below another path of the set ("" is the root, above everything).
    static func outermost(_ paths: Set<String>) -> [String] {
        if paths.contains("") { return [""] }
        let sorted = paths.sorted()
        var kept: [String] = []
        for path in sorted where !kept.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            kept.append(path)
        }
        return kept
    }
}
