import Darwin
import Foundation
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
        let clock = ContinuousClock()
        let start = clock.now
        let volumes = await Volumes.load(urls, timeout: .milliseconds(300)) { url in
            if url.path == "/hung" { Thread.sleep(forTimeInterval: 3) }
            return makeVolume(url.path)
        }
        #expect(Set(volumes.map(\.url.path)) == ["/a", "/b"])
        #expect(clock.now - start < .seconds(2))
    }
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
