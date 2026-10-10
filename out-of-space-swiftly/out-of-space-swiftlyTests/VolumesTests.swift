import Darwin
import Foundation
import Testing
@testable import out_of_space_swiftly

struct VolumesTests {
    @Test func rootVolumeIsListedFirstWithPlausibleNumbers() throws {
        let volumes = Volumes.browsable()
        let root = try #require(volumes.first)
        #expect(root.isRootFileSystem)
        #expect(root.url.path == "/")
        #expect(volumes.filter(\.isRootFileSystem).count == 1)
        #expect(!root.name.isEmpty)
        #expect(root.isLocal)
        #expect(root.isBrowsable)

        #expect(root.totalCapacity > 0)
        #expect((0...root.totalCapacity).contains(root.availableCapacity))
        #expect(root.containerUsedCapacity == root.totalCapacity - root.availableCapacity)
        #expect(root.displayedUsedCapacity == root.containerUsedCapacity)
        let used = try #require(root.usedSpace)
        #expect((1...root.totalCapacity).contains(used))
        #expect(try #require(root.fileCount) > 0)
        #expect(try #require(root.directoryCount) > 0)
        #expect(root.purgeableEstimate >= 0)
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
        let mountPoint = volume.url.path
        #expect(resolved.hasPrefix(mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"))
        #expect(volume.totalCapacity > 0)
        #expect(volume.availableCapacity <= volume.totalCapacity)

        let again = try Volumes.volume(containing: volume.url)
        #expect(again.url.path == volume.url.path)
    }

    @Test func purgeableEstimateIsNeverNegative() throws {
        var volume = try #require(Volumes.browsable().first)
        volume.availableCapacity = 100
        volume.availableCapacityForImportantUsage = 0
        #expect(volume.purgeableEstimate == 0)
        volume.availableCapacityForImportantUsage = 250
        #expect(volume.purgeableEstimate == 150)
        volume.availableCapacityForImportantUsage = nil
        #expect(volume.purgeableEstimate == 0)
    }

    @Test func onlyTheRootShowsTheContainerFigure() throws {
        var volume = try #require(Volumes.browsable().first)
        volume.totalCapacity = 1000
        volume.availableCapacity = 300
        volume.usedSpace = 200
        volume.isRootFileSystem = true
        #expect(volume.displayedUsedCapacity == 700)
        volume.isRootFileSystem = false
        #expect(volume.displayedUsedCapacity == 200)
        volume.usedSpace = nil
        #expect(volume.displayedUsedCapacity == 700)
    }
}

/// A new, empty directory under the test process's temporary directory.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "oos-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}
