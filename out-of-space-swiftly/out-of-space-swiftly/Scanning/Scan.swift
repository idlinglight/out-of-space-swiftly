import Darwin
import Foundation
import os
import Synchronization

nonisolated struct ScanOptions: Sendable {
    /// Threads reading directories at once. More than the performance cores makes it slower.
    var threadCount = ScanOptions.performanceCores
    /// Directories not entered because macOS protects them and touching them can stall (ADR-0004).
    var protectedPaths = ScanOptions.defaultProtectedPaths
    /// When the root is `/`, also walk the Data volume for the folders that exist only there.
    var includesDataVolume = true
    /// How long reading one directory may take before it is reported as slow.
    var slowAfter: Duration = .seconds(3)
    var progressInterval: Duration = .milliseconds(200)

    static var performanceCores: Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) != 0 || cores <= 0 {
            cores = Int32(ProcessInfo.processInfo.activeProcessorCount / 2)
        }
        return min(max(Int(cores), 2), 8)
    }

    /// Other apps' containers in the user's home folder.
    static var defaultProtectedPaths: [String] {
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return ["Containers", "Group Containers"].map { library.appendingPathComponent($0).path }
    }
}

nonisolated struct ScanProgress: Sendable, Equatable {
    var files = 0
    var directories = 0
    /// Bytes counted so far (allocated, before removing duplicates).
    var bytes: Int64 = 0
    var failures = 0
    /// One of the directories being read right now.
    var currentPath: String?
    /// Directories that have been taking longer than `ScanOptions.slowAfter`.
    var slowPaths: [String] = []
}

nonisolated struct ScanResult: Sendable {
    let tree: ScanTree
    let progress: ScanProgress
    let duration: Duration
    let wasCancelled: Bool
}

/// One scan of a directory tree (ADR-0004): our own `getattrlistbulk` walker on a few dedicated threads.
///
///     let scan = Scan(root: url)
///     Task { for await progress in scan.progress { … } }
///     let result = await scan.run()
///
/// Cancelling the task that awaits `run()`, or calling `cancel()`, returns the partial tree at once; a
/// thread stuck in a system call is left to finish on its own and changes nothing after that.
nonisolated final class Scan: Sendable {
    let rootPath: String
    let options: ScanOptions
    let progress: AsyncStream<ScanProgress>
    private let progressContinuation: AsyncStream<ScanProgress>.Continuation
    private let engine: ScanEngine

    init(root: URL, options: ScanOptions = ScanOptions()) {
        let path = root.resolvingSymlinksInPath().path
        rootPath = path
        self.options = options
        (progress, progressContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        engine = ScanEngine(rootPath: path, options: options)
    }

    func cancel() {
        engine.cancel()
    }

    /// Runs the scan to the end (or until cancelled) and returns the finished tree. Call once.
    func run() async -> ScanResult {
        let start = ContinuousClock.now
        let reporter = Task.detached { [engine, progressContinuation, options] in
            while !Task.isCancelled {
                progressContinuation.yield(engine.progress())
                try? await Task.sleep(for: options.progressInterval)
            }
        }
        await withTaskCancellationHandler {
            await engine.run()
        } onCancel: {
            engine.cancel()
        }
        reporter.cancel()
        let tree = engine.finish()
        let final = engine.progress()
        progressContinuation.yield(final)
        progressContinuation.finish()
        let duration = ContinuousClock.now - start
        let cancelled = engine.isCancelled
        Log.scan.notice("""
            Scanned \(self.rootPath, privacy: .private): \(final.files, privacy: .public) files, \
            \(final.directories, privacy: .public) directories, \(final.failures, privacy: .public) failures \
            in \(duration, privacy: .public)\(cancelled ? ", cancelled" : "", privacy: .public)
            """)
        return ScanResult(tree: tree, progress: final, duration: duration, wasCancelled: cancelled)
    }
}

/// An open directory; closed when the last work item that needs it as a parent is done.
private nonisolated final class DirectoryHandle: Sendable {
    let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }
}

private nonisolated struct WorkItem: Sendable {
    var node: NodeID
    /// Opened relative to `parent`; or `path` for the first item of a pass.
    var name: String
    var parent: DirectoryHandle?
    var path: String?
    /// Leave out subdirectories that were already walked (the Data volume pass).
    var dropsVisited = false
}

private nonisolated struct FileKey: Hashable {
    var device: Int32
    var number: UInt64
}


/// The shared state of one scan. `queue` holds the work stack and the threads' coming and going; changes to
/// it are made with `wakeUp` locked and broadcast, so a thread about to sleep cannot miss new work.
/// `builder` holds the tree and the sets that remove duplicates.
private nonisolated final class ScanEngine: Sendable {
    let rootPath: String
    let options: ScanOptions

    private struct QueueState: Sendable {
        var stack: [WorkItem] = []
        var busy = 0
        var threads = 0
        var cancelled = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private struct Builder {
        var tree: ScanTree
        var hardLinks: Set<FileKey> = []
        var clones: Set<FileKey> = []
        var visited: Set<FileKey> = []
        var protected: Set<FileKey> = []
        var sealed = false
        /// The group under which the Data volume pass puts what it finds, if there is one.
        var dataGroup: NodeID?
    }

    private struct InFlight {
        var node: NodeID
        var since: ContinuousClock.Instant
    }

    private let queue = Mutex(QueueState())
    private let wakeUp = NSCondition()
    private let builder: Mutex<Builder>
    private let inFlight = Mutex<[Int: InFlight]>([:])
    private let slowNodes = Mutex<Set<NodeID>>([])

    private let files = Atomic<Int>(0)
    private let directories = Atomic<Int>(0)
    private let bytes = Atomic<Int64>(0)
    private let failures = Atomic<Int>(0)

    static let dataVolumePath = "/System/Volumes/Data"

    init(rootPath: String, options: ScanOptions) {
        self.rootPath = rootPath
        self.options = options
        var info = stat()
        let found = lstat(rootPath, &info) == 0
        let name = rootPath == "/"
            ? ((try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "/")
            : URL(fileURLWithPath: rootPath).lastPathComponent
        var state = Builder(tree: ScanTree(rootPath: rootPath, rootName: name,
                                           device: found ? info.st_dev : 0, fileID: found ? info.st_ino : 0))
        for path in options.protectedPaths where lstat(path, &info) == 0 {
            state.protected.insert(FileKey(device: info.st_dev, number: info.st_ino))
        }
        builder = Mutex(state)
    }

    var isCancelled: Bool { queue.withLock { $0.cancelled } }

    func cancel() {
        var waiter: CheckedContinuation<Void, Never>?
        changeQueue { state in
            state.cancelled = true
            waiter = state.waiter
            state.waiter = nil
        }
        waiter?.resume()
    }

    /// Walks the root, then (for `/`) the Data volume.
    func run() async {
        await runPass(WorkItem(node: 0, name: "", path: rootPath))
        let group = builder.withLock { $0.dataGroup }
        if let group, !isCancelled {
            await runPass(WorkItem(node: group, name: "", path: Self.dataVolumePath, dropsVisited: true))
        }
    }

    /// Stops all changes to the tree, adds totals and order, and hands it over.
    func finish() -> ScanTree {
        let tree = builder.withLock { state in
            state.sealed = true
            return state.tree
        }
        for node in slowNodes.withLock({ $0 }) {
            tree.update(node) { $0.flags.insert(.slow) }
        }
        tree.finish()
        return tree
    }

    func progress() -> ScanProgress {
        let now = ContinuousClock.now
        let current = inFlight.withLock { $0.values.sorted { $0.since > $1.since } }
        let slow = current.filter { now - $0.since > options.slowAfter }.map(\.node)
        if !slow.isEmpty { slowNodes.withLock { $0.formUnion(slow) } }
        let paths = builder.withLock { state in
            (current.first.map { state.tree.path(of: $0.node) }, slow.map { state.tree.path(of: $0) })
        }
        return ScanProgress(files: files.load(ordering: .relaxed), directories: directories.load(ordering: .relaxed),
                            bytes: bytes.load(ordering: .relaxed), failures: failures.load(ordering: .relaxed),
                            currentPath: paths.0, slowPaths: paths.1)
    }

    // MARK: Threads

    private func changeQueue(_ change: (inout QueueState) -> Void) {
        wakeUp.lock()
        queue.withLock { change(&$0) }
        wakeUp.broadcast()
        wakeUp.unlock()
    }

    private func runPass(_ first: WorkItem) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var started = false
            changeQueue { state in
                guard !state.cancelled else { return }
                state.stack = [first]
                state.threads = options.threadCount
                state.waiter = continuation
                started = true
            }
            guard started else { return continuation.resume() }
            for index in 0 ..< options.threadCount {
                let thread = Thread { [self] in work(index) }
                thread.name = "Scan \(index + 1)"
                thread.qualityOfService = .utility
                thread.start()
            }
        }
    }

    private func work(_ index: Int) {
        ScanProcessSettings.applyToScanThread()
        let reader = DirectoryReader()
        while let item = nextItem() {
            inFlight.withLock { $0[index] = InFlight(node: item.node, since: .now) }
            process(item, with: reader)
            inFlight.withLock { _ = $0.removeValue(forKey: index) }
            changeQueue { $0.busy -= 1 }
        }
        var waiter: CheckedContinuation<Void, Never>?
        changeQueue { state in
            state.threads -= 1
            if state.threads == 0 {
                waiter = state.waiter
                state.waiter = nil
            }
        }
        waiter?.resume()
    }

    /// The next directory to read, newest first (so few directories stay open); nil when the pass is over.
    private func nextItem() -> WorkItem? {
        wakeUp.lock()
        defer { wakeUp.unlock() }
        while true {
            enum Next { case item(WorkItem), done, wait }
            let next = queue.withLock { state -> Next in
                if state.cancelled { return .done }
                if let item = state.stack.popLast() {
                    state.busy += 1
                    return .item(item)
                }
                return state.busy == 0 ? .done : .wait
            }
            switch next {
            case .item(let item): return item
            case .done: return nil
            case .wait: wakeUp.wait()
            }
        }
    }

    // MARK: Reading one directory

    private func process(_ item: WorkItem, with reader: DirectoryReader) {
        let descriptor = if let parent = item.parent {
            openat(parent.descriptor, item.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            open(item.path ?? "", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            let code = errno
            failures.add(1, ordering: .relaxed)
            builder.withLock { state in
                guard !state.sealed else { return }
                state.tree.setError(code, for: item.node)
            }
            return
        }
        let handle = DirectoryHandle(descriptor)

        // Through a firmlink, the directory opened is the Data volume's; fstat says which one it really is.
        var info = stat()
        if fstat(descriptor, &info) == 0 {
            let key = FileKey(device: info.st_dev, number: info.st_ino)
            let isNew = builder.withLock { state in
                guard !state.sealed else { return false }
                guard state.visited.insert(key).inserted else {
                    state.tree.update(item.node) { $0.flags.formUnion([.notEntered, .alreadyCounted]) }
                    return false
                }
                return true
            }
            guard isNew else { return }
        }

        var children: [(name: String, node: ScanTree.Node)] = []
        var entryErrors: [Int: Int32] = [:]
        let code = reader.read(descriptor) { entry in
            if entry.error != 0 { entryErrors[children.count] = Int32(bitPattern: entry.error) }
            children.append((entry.name, Self.node(for: entry)))
        }
        var group: (name: String, node: ScanTree.Node)?
        if item.node == 0, rootPath == "/", options.includesDataVolume, Self.isMountPoint(Self.dataVolumePath) {
            group = ("Only on the Data volume", ScanTree.Node(parent: 0, kind: .group))
        }

        var entered: [(id: NodeID, name: String)] = []
        var fileCount = 0
        var byteCount: Int64 = 0
        let appended = builder.withLock { state -> Bool in
            guard !state.sealed else { return false }
            var kept: [(name: String, node: ScanTree.Node)] = []
            var keptErrors: [(Int, Int32)] = []
            kept.reserveCapacity(children.count + 1)
            for (offset, child) in children.enumerated() {
                var node = child.node
                let key = FileKey(device: node.device, number: node.fileID)
                if node.kind == .directory {
                    if item.dropsVisited, state.visited.contains(key) { continue }
                    if state.protected.contains(key) { node.flags.formUnion([.notEntered, .protected]) }
                } else if node.kind == .file {
                    Self.markDuplicate(&node, in: &state)
                    fileCount += 1
                    byteCount += node.allocatedSize
                }
                if let error = entryErrors[offset] { keptErrors.append((kept.count, error)) }
                kept.append((child.name, node))
            }
            if let group { kept.append(group) }

            let first = state.tree.appendChildren(of: item.node, kept)
            for (offset, error) in keptErrors { state.tree.setError(error, for: first + NodeID(offset)) }
            if code != 0 { state.tree.setError(code, for: item.node) }
            if group != nil {
                let id = first + NodeID(kept.count - 1)
                state.tree.setBasePath(Self.dataVolumePath, for: id)
                state.dataGroup = id
            }
            for (offset, child) in kept.enumerated()
            where child.node.kind == .directory && !child.node.flags.contains(.notEntered) {
                entered.append((first + NodeID(offset), child.name))
            }
            return true
        }
        guard appended else { return }

        files.add(fileCount, ordering: .relaxed)
        directories.add(1, ordering: .relaxed)
        bytes.add(byteCount, ordering: .relaxed)
        if code != 0 || !entryErrors.isEmpty { failures.add(1, ordering: .relaxed) }

        guard !entered.isEmpty else { return }
        let items = entered.reversed().map { child in
            WorkItem(node: child.id, name: child.name, parent: handle, dropsVisited: item.dropsVisited)
        }
        changeQueue { $0.stack.append(contentsOf: items) }
    }

    /// Counts a file with several links once per inode, and a set of full clones once per clone ID.
    private static func markDuplicate(_ node: inout ScanTree.Node, in state: inout Builder) {
        if node.flags.contains(.hardLinked),
           !state.hardLinks.insert(FileKey(device: node.device, number: node.fileID)).inserted {
            node.flags.insert(.duplicate)
            return
        }
        if node.flags.contains(.sharesAllBlocks), node.cloneID != 0,
           !state.clones.insert(FileKey(device: node.device, number: node.cloneID)).inserted {
            node.flags.insert(.duplicate)
        }
    }

    static func node(for entry: DirectoryEntry) -> ScanTree.Node {
        var node = ScanTree.Node(parent: 0, kind: .other, device: entry.device, fileID: entry.fileID)
        if entry.flags & UInt32(SF_FIRMLINK) != 0 { node.flags.insert(.firmlink) }
        if entry.flags & UInt32(SF_DATALESS) != 0 { node.flags.insert(.dataless) }
        switch entry.objectType {
        case VREG.rawValue:
            node.kind = .file
            node.allocatedSize = entry.allocatedSize
            node.logicalSize = entry.logicalSize
            node.cloneID = entry.cloneID
            if entry.linkCount > 1 { node.flags.insert(.hardLinked) }
            if entry.flags & UInt32(UF_COMPRESSED) != 0 { node.flags.insert(.compressed) }
            if entry.extendedFlags & UInt64(EF_IS_SPARSE) != 0 { node.flags.insert(.sparse) }
            if entry.extendedFlags & UInt64(EF_IS_PURGEABLE) != 0 { node.flags.insert(.purgeable) }
            if entry.extendedFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 {
                node.flags.insert(.sharesAllBlocks)
            } else if entry.extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 {
                node.flags.insert(.mayShareBlocks)
            }
        case VDIR.rawValue:
            node.kind = .directory
            if entry.mountStatus & UInt32(DIR_MNTSTATUS_TRIGGER) != 0 {
                node.kind = .automount
                node.flags.insert(.notEntered)
            } else if entry.mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 {
                node.kind = .mountPoint
                node.flags.insert(.notEntered)
            } else if node.flags.contains(.dataless) {
                node.flags.insert(.notEntered)
            }
        case VLNK.rawValue:
            node.kind = .symlink
        default:
            break
        }
        return node
    }

    static func isMountPoint(_ path: String) -> Bool {
        var mount = statfs()
        guard statfs(path, &mount) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: mount.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == path
    }
}
