import CoreServices
import Darwin
import Foundation

/// One path an `FSEventStream` reported, and what it said about it.
nonisolated struct FileSystemChange: Sendable, Hashable {
    /// Absolute and resolved (see `FileSystemEvents.root`), without a trailing slash. With directory-level
    /// events, the directory whose entries changed.
    var path: String
    var flags: Flags
    /// FSEvents' event ID; 0 for `rootChanged`.
    var eventID: UInt64

    /// FSEvents' event flags; `rawValue` keeps the ones not named here.
    nonisolated struct Flags: OptionSet, Sendable, Hashable {
        let rawValue: UInt32

        /// Events were coalesced: rescan `path` recursively, not just its entries.
        static let mustScanSubdirectories = Flags(kFSEventStreamEventFlagMustScanSubDirs)
        /// Events were dropped in this process (`userDropped`) or the kernel (`kernelDropped`); comes with
        /// `mustScanSubdirectories`. The watcher also reports `userDropped` when its own buffer overflows.
        static let userDropped = Flags(kFSEventStreamEventFlagUserDropped)
        static let kernelDropped = Flags(kFSEventStreamEventFlagKernelDropped)
        static let eventIDsWrapped = Flags(kFSEventStreamEventFlagEventIdsWrapped)
        /// The watched root itself, or a folder above it, was moved, deleted or created.
        static let rootChanged = Flags(kFSEventStreamEventFlagRootChanged)
        /// A volume was mounted or unmounted at `path`, inside the watched tree.
        static let mount = Flags(kFSEventStreamEventFlagMount)
        static let unmount = Flags(kFSEventStreamEventFlagUnmount)
        // Only set with file-level events. FSEvents ORs them over everything that happened to the path
        // within one batch, so a file created and deleted again carries both.
        static let itemCreated = Flags(kFSEventStreamEventFlagItemCreated)
        static let itemRemoved = Flags(kFSEventStreamEventFlagItemRemoved)
        static let itemRenamed = Flags(kFSEventStreamEventFlagItemRenamed)
        static let itemModified = Flags(kFSEventStreamEventFlagItemModified)
        static let isDirectory = Flags(kFSEventStreamEventFlagItemIsDir)
        static let isFile = Flags(kFSEventStreamEventFlagItemIsFile)

        init(rawValue: UInt32) { self.rawValue = rawValue }
        private init(_ flag: Int) { rawValue = UInt32(flag) }
    }
}

/// Change notifications for one directory tree, from an `FSEventStream`, as an async stream of batches.
///
/// FSEvents reports real paths: a tree opened as `/var/folders/…` is reported under `/private/var/folders/…`.
/// The watcher resolves its root with `realpath(3)` and consumers compare event paths against `root`, or use
/// `relativePath(of:)`.
nonisolated struct FileSystemEvents: Sendable {
    /// The watched directory, resolved.
    let root: String
    /// One element per FSEvents callback.
    ///
    /// - At most `bufferedBatches` wait for the consumer. Beyond that the oldest are dropped, and a batch
    ///   asking for a recursive rescan of the root follows (see `yield(_:root:to:)`).
    /// - Root moved, deleted or created again: a `rootChanged` change at `root`. The stream stays open:
    ///   FSEvents keeps watching the path, and once a directory is back there its changes are reported as
    ///   before (verified). The consumer checks whether the root still exists and cancels if it is done.
    /// - The root's volume unmounted: FSEvents reports nothing at all (verified with a disk image), so watch
    ///   for unmounts separately. A volume mounted or unmounted *inside* the tree reports `mount` or `unmount`
    ///   at its mount point (verified).
    ///
    /// Ends when the consuming task is cancelled or the stream is dropped; the FSEventStream is then stopped
    /// and released, and no callback follows.
    let changes: AsyncStream<[FileSystemChange]>

    /// About a minute of changes at the default latency.
    static let bufferedBatches = 64

    nonisolated enum WatchError: Error {
        case cannotCreateStream, cannotStartStream, pathNotRepresentable
    }

    /// Starts watching `directory` and everything below it; events are buffered from here on.
    ///
    /// - Parameters:
    ///   - latency: How long FSEvents collects events into one batch after the first one arrives.
    ///   - fileLevel: Report each file (`kFSEventStreamCreateFlagFileEvents`) instead of the directories
    ///     whose entries changed. Off by default: the scanner rescans directories either way, file-level
    ///     events multiply the volume (an install or build touching 100,000 files gives that many events
    ///     rather than one per directory), and their item flags are ORed over a batch, so they can't stand
    ///     in for a fresh look at the directory.
    ///   - onStop: Called on the watcher's queue once the stream is stopped and released.
    static func watch(
        _ directory: URL,
        latency: Duration = .seconds(1),
        fileLevel: Bool = false,
        onStop: (@Sendable () -> Void)? = nil
    ) throws -> FileSystemEvents {
        let root = try resolvedPath(directory)
        let (changes, continuation) = AsyncStream.makeStream(
            of: [FileSystemChange].self, bufferingPolicy: .bufferingNewest(bufferedBatches)
        )
        let watch = Watch(root: root, continuation: continuation, onStop: onStop)

        // The stream retains the watch through these callbacks and releases it in FSEventStreamRelease.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(watch).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Watch>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Watch>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        // WatchRoot reports a moved or deleted root as `rootChanged`.
        var flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        if fileLevel { flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents) }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, ids in
                guard let info else { return }
                Unmanaged<Watch>.fromOpaque(info).takeUnretainedValue()
                    .deliver(count: count, paths: paths, flags: flags, ids: ids)
            },
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency / .seconds(1),
            flags
        ) else { throw WatchError.cannotCreateStream }

        watch.stream = stream
        FSEventStreamSetDispatchQueue(stream, watch.queue)
        guard FSEventStreamStart(stream) else {
            watch.stream = nil
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw WatchError.cannotStartStream
        }
        continuation.onTermination = { _ in watch.queue.async { watch.stop() } }
        return FileSystemEvents(root: root, changes: changes)
    }

    /// `path` relative to `root`: "a/b" for a path inside it, nil for one outside. "" stands for the root and
    /// everything below it, so rescan all: it is returned for `root` itself and for any path above it, where
    /// FSEvents reports `rootChanged` and may report coalesced or dropped events (`mustScanSubdirectories`).
    func relativePath(of path: String) -> String? {
        if Self.path(path, contains: root) { return "" }
        guard Self.path(root, contains: path) else { return nil }
        return String(path.dropFirst(root == "/" ? 1 : root.count + 1))
    }

    /// Whether `path` is `ancestor` or lies below it. Both absolute, without a trailing slash.
    static func path(_ ancestor: String, contains path: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// Yields `batch` into the bounded stream. When the buffer is full, the oldest batch is dropped; a batch
    /// asking for a recursive rescan of `root` then follows, which covers whatever was lost. That batch is the
    /// newest, so it outlives what it replaces; if later batches push it out too, those yields report drops
    /// and bring another.
    static func yield(
        _ batch: [FileSystemChange], root: String, to continuation: AsyncStream<[FileSystemChange]>.Continuation
    ) {
        guard case .dropped = continuation.yield(batch) else { return }
        continuation.yield([FileSystemChange(path: root, flags: [.mustScanSubdirectories, .userDropped], eventID: 0)])
    }

    /// `url`'s path as FSEvents reports it.
    static func resolvedPath(_ url: URL) throws -> String {
        let resolved: Result<String, any Error> = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return .failure(WatchError.pathNotRepresentable) }
            guard let resolved = realpath(path, nil) else {
                return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT))
            }
            defer { free(resolved) }
            return .success(String(cString: resolved))
        }
        return try resolved.get()
    }
}

/// The callback's state. `stream` is set before the stream starts and afterwards only touched on `queue`,
/// where FSEvents delivers its callbacks too.
private nonisolated final class Watch: @unchecked Sendable {
    let root: String
    let continuation: AsyncStream<[FileSystemChange]>.Continuation
    let onStop: (@Sendable () -> Void)?
    let queue = DispatchQueue(label: "at.idling.out-of-space-swiftly.fsevents", qos: .utility)
    var stream: FSEventStreamRef?

    init(root: String, continuation: AsyncStream<[FileSystemChange]>.Continuation, onStop: (@Sendable () -> Void)?) {
        self.root = root
        self.continuation = continuation
        self.onStop = onStop
    }

    func deliver(
        count: Int,
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>,
        ids: UnsafePointer<FSEventStreamEventId>
    ) {
        guard stream != nil else { return }
        // Without kFSEventStreamCreateFlagUseCFTypes, `paths` is a C array of C strings.
        let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        let batch = (0..<count).map { i in
            var path = String(cString: cPaths[i])
            // Directory-level events end in "/".
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return FileSystemChange(path: path, flags: .init(rawValue: flags[i]), eventID: ids[i])
        }
        FileSystemEvents.yield(batch, root: root, to: continuation)
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        onStop?()
    }
}
