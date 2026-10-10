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
        /// `mustScanSubdirectories`.
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
    /// One element per FSEvents callback. Ends when the consuming task is cancelled or the stream is
    /// dropped; the FSEventStream is then stopped and released, and no callback follows.
    let changes: AsyncStream<[FileSystemChange]>

    nonisolated enum WatchError: Error {
        case cannotCreateStream, cannotStartStream
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
        let (changes, continuation) = AsyncStream.makeStream(of: [FileSystemChange].self)
        let watch = Watch(continuation: continuation, onStop: onStop)

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
        let seconds = Double(latency.components.seconds) + Double(latency.components.attoseconds) * 1e-18
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
            seconds,
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

    /// `path` relative to `root`: "" for the root itself, nil for paths outside it.
    func relativePath(of path: String) -> String? {
        if path == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// `url`'s path as FSEvents reports it.
    static func resolvedPath(_ url: URL) throws -> String {
        let (resolved, error) = url.withUnsafeFileSystemRepresentation { path in
            let resolved = path.flatMap { realpath($0, nil) }
            return (resolved, errno)
        }
        guard let resolved else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .ENOENT) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// The callback's state. `stream` is set before the stream starts and afterwards only touched on `queue`,
/// where FSEvents delivers its callbacks too.
private nonisolated final class Watch: @unchecked Sendable {
    let continuation: AsyncStream<[FileSystemChange]>.Continuation
    let onStop: (@Sendable () -> Void)?
    let queue = DispatchQueue(label: "at.idling.out-of-space-swiftly.fsevents", qos: .utility)
    var stream: FSEventStreamRef?

    init(continuation: AsyncStream<[FileSystemChange]>.Continuation, onStop: (@Sendable () -> Void)?) {
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
        continuation.yield(batch)
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
