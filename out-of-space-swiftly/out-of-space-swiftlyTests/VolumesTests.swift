import Darwin
import Foundation
import Synchronization
import Testing
@testable import out_of_space_swiftly

/// Only `/` (with its Data volume) is read; listing mount points reads no volume.
struct VolumesTests {
    @Test func rootIsAmongTheBrowsableMountPoints() {
        #expect(Volumes.browsableVolumeURLs().contains { $0.path == "/" })
    }

    @Test func rootVolumeHasPlausibleNumbers() throws {
        let root = try VolumeInfo.load(URL(filePath: "/", directoryHint: .isDirectory))
        #expect(root.isRootFileSystem)
        #expect(!root.name.isEmpty)
        #expect(root.isLocal)
        #expect(root.isBrowsable)

        #expect(root.totalCapacity > 0)
        #expect((0...root.totalCapacity).contains(root.availableCapacity))
        #expect(root.containerUsedCapacity == root.totalCapacity - root.availableCapacity)
        #expect(root.purgeableEstimate >= 0)

        // The system volume's own figures plus the Data volume's.
        let system = root.attributes
        let data = try #require(root.dataVolumeAttributes)
        let systemUsed = try #require(system.usedSpace), dataUsed = try #require(data.usedSpace)
        let systemFiles = try #require(system.fileCount), dataFiles = try #require(data.fileCount)
        let systemDirectories = try #require(system.directoryCount)
        let dataDirectories = try #require(data.directoryCount)
        let used = try #require(root.usedSpace)
        #expect(used == systemUsed + dataUsed)
        #expect((1...root.totalCapacity).contains(used))
        #expect(root.displayedUsedCapacity == used)
        #expect(root.fileCount == systemFiles + dataFiles)
        #expect(root.directoryCount == systemDirectories + dataDirectories)
        #expect(systemFiles > 0 && dataFiles > 0)
    }

    /// The getattrlist buffer is parsed at fixed offsets; a wrong order would show up as numbers that
    /// disagree with statfs.
    @Test func volumeAttributesAgreeWithStatfs() throws {
        let attributes = try VolumeAttributes.read(volumeRoot: URL(filePath: "/"))
        var fs = statfs()
        try #require(statfs("/", &fs) == 0)
        let blockSize = Int64(fs.f_bsize)
        #expect(attributes.size == Int64(fs.f_blocks) * blockSize)
        let available = try #require(attributes.availableSpace)
        // Free space moves while the test runs.
        #expect(abs(available - Int64(fs.f_bavail) * blockSize) < 1 << 30)
        let used = try #require(attributes.usedSpace)
        #expect((1...(Int64(fs.f_blocks) * blockSize)).contains(used))
    }

    @Test func temporaryDirectoryLooksUpItsVolume() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let volume = try Volumes.volume(containing: directory)
        let resolved = try FileSystemEvents.resolvedPath(directory)
        #expect(FileSystemEvents.path(volume.url.path, contains: resolved))
        #expect(volume.totalCapacity > 0)
        #expect(volume.availableCapacity <= volume.totalCapacity)
    }

    @Test func purgeableEstimateIsNeverNegative() {
        #expect(makeVolume(available: 100, important: 0).purgeableEstimate == 0)
        #expect(makeVolume(available: 100, important: 250).purgeableEstimate == 150)
        #expect(makeVolume(available: 100, important: nil).purgeableEstimate == 0)
    }

    @Test func usedFiguresAddTheDataVolumeAndNameTheRest() {
        let root = makeVolume(root: true, total: 1000, available: 300, used: 50, dataUsed: 600)
        #expect(root.usedSpace == 650)
        #expect(root.displayedUsedCapacity == 650)
        #expect(root.containerUsedCapacity == 700)
        #expect(root.otherContainerUsage == 50)

        let other = makeVolume(total: 1000, available: 300, used: 200)
        #expect(other.displayedUsedCapacity == 200)
        #expect(other.otherContainerUsage == 500)

        let unknown = makeVolume(total: 1000, available: 300, used: nil)
        #expect(unknown.usedSpace == nil)
        #expect(unknown.displayedUsedCapacity == 700)
        #expect(unknown.otherContainerUsage == 0)
    }

    @Test func rootComesFirstThenByName() {
        let volumes = Volumes.ordered([
            makeVolume("/Volumes/b", name: "b"), makeVolume("/", name: "z", root: true), makeVolume("/Volumes/a", name: "A"),
        ])
        #expect(volumes.map(\.name) == ["z", "A", "b"])
    }

    @Test func aVolumeThatHangsIsLeftOut() async {
        let urls = ["/a", "/hung", "/b"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        // No clock in here: on a busy machine the timeout itself fires late. The hung volume answers when it is
        // released, which is after `load` has returned. It gives up after half a minute, so that a `load` that
        // waits for it fails this test instead of hanging it.
        let release = DispatchSemaphore(value: 0)
        let gaveUp = Flag()
        let volumes = await Volumes.load(urls, timeout: .seconds(1)) { url in
            if url.path == "/hung", release.wait(timeout: .now() + 30) == .timedOut { gaveUp.set() }
            return makeVolume(url.path)
        }
        #expect(gaveUp.isSet == false, "load returned only after the hung volume had answered")
        release.signal()
        #expect(Set(volumes.map(\.url.path)) == ["/a", "/b"])
    }

    /// GCD starts no more threads for its global queues while as many threads as there are cores are running.
    /// A process that busy still gets its volumes, and its timeout, without waiting for one of those threads.
    /// No clock here either: the process stays busy until `load` has returned.
    @Test func aBusyProcessStillGetsItsVolumesOnTime() async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let running = Tally()
        let stop = Flag()
        let busyGaveUp = Flag()
        let release = DispatchSemaphore(value: 0)
        defer {
            stop.set()
            release.signal()
        }
        // At utility priority, below the other tests' work. They give up so that a `load` that waits for
        // them fails this test instead of hanging it.
        for _ in 0 ..< cores {
            DispatchQueue.global(qos: .utility).async {
                running.add()
                let giveUp = ContinuousClock.now + .seconds(10)
                var x = 0.0
                while !stop.isSet, !busyGaveUp.isSet {
                    for _ in 0 ..< 100_000 { x = (x + 1).squareRoot() }
                    if ContinuousClock.now > giveUp { busyGaveUp.set() }
                }
            }
        }
        // Fewer start when other tests hold some of those threads; the pool is as busy as it gets then, too.
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(300)
        while running.count < cores, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }

        // Volumes that answer: `load` returns when they are in. The timeout is far away, so that nothing
        // here depends on how soon their threads get to run.
        let healthy = ["/a", "/b"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        let volumes = await Volumes.load(healthy, timeout: .seconds(60)) { makeVolume($0.path) }
        #expect(Set(volumes.map(\.url.path)) == ["/a", "/b"])
        #expect(busyGaveUp.isSet == false, "the volumes arrived only after the process had stopped being busy")

        // A volume that hangs: `load` returns when the timeout fires.
        let hungGaveUp = Flag()
        let hung = [URL(filePath: "/hung", directoryHint: .isDirectory)]
        let none = await Volumes.load(hung, timeout: .milliseconds(200)) { url in
            if release.wait(timeout: .now() + 30) == .timedOut { hungGaveUp.set() }
            return makeVolume(url.path)
        }
        #expect(none.isEmpty)
        #expect(hungGaveUp.isSet == false, "the timeout fired only after the hung volume had answered")
        #expect(busyGaveUp.isSet == false, "the timeout fired only after the process had stopped being busy")
    }
}

private final class Tally: Sendable {
    private let value = Mutex(0)
    func add() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private func makeVolume(
    _ path: String = "/Volumes/Test", name: String = "Test", root: Bool = false, total: Int64 = 1000,
    available: Int64 = 300, important: Int64? = nil, used: Int64? = nil, dataUsed: Int64? = nil
) -> VolumeInfo {
    VolumeInfo(
        url: URL(filePath: path, directoryHint: .isDirectory),
        name: name,
        totalCapacity: total,
        availableCapacity: available,
        availableCapacityForImportantUsage: important,
        attributes: VolumeAttributes(usedSpace: used),
        dataVolumeAttributes: dataUsed.map { VolumeAttributes(usedSpace: $0) },
        isRootFileSystem: root,
        isRemovable: false,
        isEjectable: false,
        isLocal: true,
        isBrowsable: true,
        isReadOnly: false
    )
}
