import Foundation
import Synchronization
import Testing
@testable import out_of_space_swiftly

@Suite(.timeLimit(.minutes(1)))
struct FileSystemEventsTests {
    @Test func reportsChangedDirectoriesAndStopsWhenCancelled() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subdirectory = directory.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)

        let stopped = Flag()
        let events = try FileSystemEvents.watch(directory, latency: .milliseconds(100), onStop: { stopped.set() })
        let resolved = try FileSystemEvents.resolvedPath(directory)
        #expect(events.root == resolved)
        let sub = events.root + "/sub"
        let log = ChangeLog()
        let consumer = Task {
            for await batch in events.changes { log.append(batch) }
        }

        let file = subdirectory.appending(path: "a.txt")
        let renamed = subdirectory.appending(path: "b.txt")
        let steps: [(String, () throws -> Void)] = [
            ("create", { try Data("hello".utf8).write(to: file) }),
            ("rename", { try FileManager.default.moveItem(at: file, to: renamed) }),
            ("delete", { try FileManager.default.removeItem(at: renamed) }),
        ]
        for (name, step) in steps {
            let before = log.count(covering: sub)
            try step()
            let seen = try await eventually { log.count(covering: sub) > before }
            #expect(seen, "no event for the subdirectory after \(name)")
        }

        let before = log.count(covering: events.root)
        try FileManager.default.createDirectory(at: directory.appending(path: "new"), withIntermediateDirectories: false)
        #expect(try await eventually { log.count(covering: events.root) > before }, "no event for the root")
        #expect(log.paths.allSatisfy { events.relativePath(of: $0) != nil })

        consumer.cancel()
        await consumer.value
        #expect(try await eventually { stopped.isSet })
    }

    @Test func reportsAMovedRoot() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appending(path: "root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let events = try FileSystemEvents.watch(directory, latency: .milliseconds(100))
        let log = ChangeLog()
        let consumer = Task {
            for await batch in events.changes { log.append(batch) }
        }
        defer { consumer.cancel() }

        try FileManager.default.moveItem(at: directory, to: parent.appending(path: "moved"))
        let seen = try await eventually {
            log.changes.contains { $0.path == events.root && $0.flags.contains(.rootChanged) }
        }
        #expect(seen)
    }

    @Test func fileLevelEventsNameTheFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let events = try FileSystemEvents.watch(directory, latency: .milliseconds(100), fileLevel: true)
        let log = ChangeLog()
        let consumer = Task {
            for await batch in events.changes { log.append(batch) }
        }
        defer { consumer.cancel() }

        try Data("hello".utf8).write(to: directory.appending(path: "a.txt"))
        let path = events.root + "/a.txt"
        let seen = try await eventually {
            log.changes.contains { $0.path == path && $0.flags.isSuperset(of: [.itemCreated, .isFile]) }
        }
        #expect(seen)
    }

    @Test func droppingTheStreamStopsWatching() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stopped = Flag()
        _ = try FileSystemEvents.watch(directory, onStop: { stopped.set() })
        #expect(try await eventually { stopped.isSet })
    }

    @Test func watchingAMissingDirectoryThrows() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "oos-missing-\(UUID().uuidString)")
        #expect(throws: POSIXError.self) { try FileSystemEvents.watch(missing) }
    }
    @Test func relativePaths() {
        let events = FileSystemEvents(root: "/r/w", changes: AsyncStream { $0.finish() })
        #expect(events.relativePath(of: "/r/w") == "")
        #expect(events.relativePath(of: "/r/w/a/b") == "a/b")
        #expect(events.relativePath(of: "/r/wx/a") == nil)
        #expect(events.relativePath(of: "/r/x") == nil)
        // At or above the root: rescan all.
        #expect(events.relativePath(of: "/r") == "")
        #expect(events.relativePath(of: "/") == "")

        let everything = FileSystemEvents(root: "/", changes: AsyncStream { $0.finish() })
        #expect(everything.relativePath(of: "/") == "")
        #expect(everything.relativePath(of: "/a/b") == "a/b")
    }

    @Test func droppedBatchesAreFollowedByARescanOfTheRoot() async {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [FileSystemChange].self, bufferingPolicy: .bufferingNewest(2)
        )
        let batches = (1...5).map { [FileSystemChange(path: "/r/\($0)", flags: [], eventID: UInt64($0))] }
        for batch in batches { FileSystemEvents.yield(batch, root: "/r", to: continuation) }
        continuation.finish()

        var received: [[FileSystemChange]] = []
        for await batch in stream { received.append(batch) }
        let rescan = FileSystemChange(path: "/r", flags: [.mustScanSubdirectories, .userDropped], eventID: 0)
        #expect(received == [batches[4], [rescan]])
    }

    @Test func batchesThatFitArriveUnchanged() async {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [FileSystemChange].self, bufferingPolicy: .bufferingNewest(FileSystemEvents.bufferedBatches)
        )
        let batches = (1...3).map { [FileSystemChange(path: "/r/\($0)", flags: [], eventID: UInt64($0))] }
        for batch in batches { FileSystemEvents.yield(batch, root: "/r", to: continuation) }
        continuation.finish()

        var received: [[FileSystemChange]] = []
        for await batch in stream { received.append(batch) }
        #expect(received == batches)
    }
}

/// Polls `condition` until it holds or `timeout` passes.
private func eventually(within timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}

private final class ChangeLog: Sendable {
    private let batches = Mutex<[[FileSystemChange]]>([])

    func append(_ batch: [FileSystemChange]) { batches.withLock { $0.append(batch) } }
    var changes: [FileSystemChange] { batches.withLock { $0.flatMap(\.self) } }
    var paths: [String] { changes.map(\.path) }

    /// Changes that tell a consumer to rescan `directory`: its own, or a recursive rescan above it.
    func count(covering directory: String) -> Int {
        changes.count { change in
            change.path == directory
                || (change.flags.contains(.mustScanSubdirectories)
                    && FileSystemEvents.path(change.path, contains: directory))
        }
    }
}

private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
