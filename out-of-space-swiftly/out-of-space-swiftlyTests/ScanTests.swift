import Darwin
import Foundation
import Testing
@testable import out_of_space_swiftly

extension ScanOptions {
    /// Options for scanning fixtures: no protected paths, so not even the real `~/Library` folders' own
    /// metadata is looked up.
    static var fixture: ScanOptions {
        var options = ScanOptions()
        options.protectedPaths = []
        return options
    }
}

/// Scans of generated trees. Every test builds its own tree in a temporary directory; nothing else on the
/// disk is read.
struct ScanTests {
    private func scan(_ fixture: FixtureTree, options: ScanOptions = .fixture) async -> ScanResult {
        await Scan(root: fixture.root, options: options).run()
    }

    private func find(_ path: String, in tree: ScanTree) -> NodeID? {
        var current = tree.root
        for component in path.split(separator: "/") {
            guard let next = tree.children(of: current).first(where: { tree.name(of: $0) == component }) else { return nil }
            current = next
        }
        return current
    }

    /// Every directory's size is the sum of its children's, and its count the sum of theirs plus them.
    private func expectConsistentTotals(_ tree: ScanTree, sourceLocation: SourceLocation = #_sourceLocation) {
        for id in 0 ..< NodeID(tree.count) where tree.node(id).childCount > 0 {
            let children = tree.children(of: id)
            #expect(tree.size(of: id) == children.reduce(0) { $0 + tree.size(of: $1) }, sourceLocation: sourceLocation)
            #expect(tree.node(id).descendantCount == children.reduce(Int32(0)) { $0 + tree.node($1).descendantCount + 1 },
                    sourceLocation: sourceLocation)
        }
    }

    @Test func countsAllocatedSizesOfAPlainTree() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a/one.bin", size: 10_000)
        try fixture.file("a/b/two.bin", size: 5_000)
        try fixture.file("c.txt", size: 1)
        let result = await scan(fixture)
        let tree = result.tree

        let expected = ["a/one.bin", "a/b/two.bin", "c.txt"].reduce(Int64(0)) { $0 + fixture.allocatedSize($1) }
        #expect(!result.wasCancelled)
        #expect(tree.size(of: tree.root) == expected)
        #expect(tree.node(tree.root).descendantCount == 5)
        #expect(result.progress.files == 3)
        #expect(result.progress.directories == 3)
        #expect(tree.children(of: tree.root).map { tree.name(of: $0) } == ["a", "c.txt"])
        let two = try #require(find("a/b/two.bin", in: tree))
        #expect(tree.kind(of: two) == .file)
        #expect(tree.node(two).logicalSize == 5_000)
        #expect(tree.path(of: two) == fixture.url("a/b/two.bin").path)
        #expect(tree.lineage(of: two).map { tree.name(of: $0) }.dropFirst() == ["a", "b", "two.bin"])
        expectConsistentTotals(tree)
    }

    @Test func hardLinksCountOnce() async throws {
        let fixture = try FixtureTree()
        try fixture.file("x/original.bin", size: 100_000)
        try fixture.hardLink("y/link.bin", to: "x/original.bin")
        let tree = await scan(fixture).tree

        let original = try #require(find("x/original.bin", in: tree))
        let link = try #require(find("y/link.bin", in: tree))
        #expect(tree.size(of: tree.root) == fixture.allocatedSize("x/original.bin"))
        #expect(tree.flags(of: original).contains(.hardLinked))
        #expect(tree.flags(of: link).contains(.hardLinked))
        #expect([original, link].count { tree.flags(of: $0).contains(.duplicate) } == 1)
        expectConsistentTotals(tree)
    }

    @Test func fullClonesCountOnce() async throws {
        let fixture = try FixtureTree()
        try fixture.file("source.bin", size: 1 << 20)
        try fixture.clone("copies/first.bin", of: "source.bin")
        try fixture.clone("copies/second.bin", of: "source.bin")
        let tree = await scan(fixture).tree

        let members = try ["source.bin", "copies/first.bin", "copies/second.bin"].map { try #require(find($0, in: tree)) }
        #expect(members.allSatisfy { tree.flags(of: $0).contains(.sharesAllBlocks) })
        #expect(members.count { tree.flags(of: $0).contains(.duplicate) } == 2)
        #expect(tree.size(of: tree.root) == fixture.allocatedSize("source.bin"))
        expectConsistentTotals(tree)
    }

    @Test func sparseFilesCountTheirAllocatedBytes() async throws {
        let fixture = try FixtureTree()
        try fixture.sparseFile("sparse.bin", length: 1 << 30)
        let tree = await scan(fixture).tree

        let sparse = try #require(find("sparse.bin", in: tree))
        #expect(tree.node(sparse).logicalSize == 1 << 30)
        #expect(tree.size(of: sparse) == fixture.allocatedSize("sparse.bin"))
        #expect(tree.size(of: sparse) < 1 << 20)
        #expect(tree.flags(of: sparse).contains(.sparse))
    }

    @Test func unreadableDirectoryIsReportedAndTheScanGoesOn() async throws {
        let fixture = try FixtureTree()
        try fixture.file("locked/secret.bin", size: 50_000)
        try fixture.file("open/visible.bin", size: 20_000)
        try fixture.setPermissions("locked", 0o000)
        let result = await scan(fixture)
        let tree = result.tree

        let locked = try #require(find("locked", in: tree))
        #expect(tree.error(of: locked) == EACCES)
        #expect(ScanFailure(errno: try #require(tree.error(of: locked))) == .noPermission)
        #expect(tree.flags(of: locked).contains(.failed))
        #expect(tree.size(of: locked) == 0)
        #expect(tree.size(of: tree.root) == fixture.allocatedSize("open/visible.bin"))
        #expect(result.progress.failures == 1)
        #expect(!result.wasCancelled)
    }

    @Test func symlinksAreListedButNotFollowed() async throws {
        let fixture = try FixtureTree()
        try fixture.file("data/file.bin", size: 8_192)
        try fixture.symlink("data/loop", to: "..")
        try fixture.symlink("outside", to: "/usr")
        let tree = await scan(fixture).tree

        for path in ["data/loop", "outside"] {
            let link = try #require(find(path, in: tree))
            #expect(tree.kind(of: link) == .symlink)
            #expect(tree.node(link).childCount == 0)
        }
        #expect(tree.size(of: tree.root) == fixture.allocatedSize("data/file.bin"))
    }

    @Test func pathsLongerThanPathMaxAreScanned() async throws {
        let fixture = try FixtureTree()
        try fixture.directory("deep")
        let length = try fixture.deepTree(below: "deep", depth: 120, name: "directory", fileSize: 4_096)
        #expect(length > Int(PATH_MAX))
        let tree = await scan(fixture).tree

        var current = try #require(find("deep", in: tree))
        for _ in 0 ..< 120 {
            current = try #require(tree.children(of: current).first)
        }
        let bottom = try #require(tree.children(of: current).first)
        #expect(tree.name(of: bottom) == "bottom.bin")
        #expect(tree.size(of: tree.root) > 0)
        #expect(tree.node(tree.root).descendantCount == 1 + 120 + 1)
    }

    @Test func protectedPathsAreNotEntered() async throws {
        let fixture = try FixtureTree()
        try fixture.file("Library/Containers/com.example.app/Data/big.bin", size: 200_000)
        try fixture.file("Library/Preferences/settings.plist", size: 1_000)
        var options = ScanOptions.fixture
        options.protectedPaths = [fixture.url("Library/Containers").path]
        let tree = await scan(fixture, options: options).tree

        let containers = try #require(find("Library/Containers", in: tree))
        #expect(tree.flags(of: containers).isSuperset(of: [.protected, .notEntered]))
        #expect(tree.node(containers).childCount == 0)
        #expect(tree.size(of: tree.root) == fixture.allocatedSize("Library/Preferences/settings.plist"))
    }

    @Test func cancellingBeforeTheStartReturnsAtOnce() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a/b.bin", size: 1_000)
        let scan = Scan(root: fixture.root, options: .fixture)
        scan.cancel()
        let result = await scan.run()
        #expect(result.wasCancelled)
        #expect(result.tree.count == 1)
    }

    @Test func cancellingMidwayLeavesAConsistentTree() async throws {
        let fixture = try FixtureTree()
        for directory in 0 ..< 200 {
            for file in 0 ..< 10 {
                try fixture.file("d\(directory)/sub/f\(file).bin", size: 100)
            }
        }
        let scan = Scan(root: fixture.root, options: .fixture)
        let task = Task { await scan.run() }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()
        let result = await task.value
        expectConsistentTotals(result.tree)
        if !result.wasCancelled {
            #expect(result.progress.files == 2_000)
        }
    }

    @Test func aThreadCountBelowOneStillScans() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a.bin", size: 1_000)
        var options = ScanOptions.fixture
        options.threadCount = 0
        let result = await scan(fixture, options: options)
        #expect(result.progress.files == 1)
    }

    @Test func progressIsReportedAndTheStreamEnds() async throws {
        let fixture = try FixtureTree()
        for index in 0 ..< 50 {
            try fixture.file("dir\(index % 5)/file\(index).bin", size: 2_000)
        }
        var options = ScanOptions.fixture
        options.progressInterval = .milliseconds(1)
        let scan = Scan(root: fixture.root, options: options)
        let collector = Task {
            var last: ScanProgress?
            for await progress in scan.progress { last = progress }
            return last
        }
        let result = await scan.run()
        let last = try #require(await collector.value)
        #expect(last.files == 50)
        #expect(last.directories == 6)
        #expect(last == result.progress)
    }
}

struct DirectoryReaderTests {
    @Test func readsNamesTypesAndSizes() throws {
        let fixture = try FixtureTree()
        try fixture.file("Größe ✓.txt", size: 3_000)
        try fixture.directory("folder")
        try fixture.symlink("link", to: "folder")
        let descriptor = open(fixture.root.path, O_RDONLY | O_DIRECTORY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }

        var entries: [String: DirectoryEntry] = [:]
        let error = DirectoryReader(bufferSize: 512).read(descriptor) { entries[$0.name] = $0 }
        #expect(error == 0)
        #expect(Set(entries.keys) == ["Größe ✓.txt", "folder", "link"])
        let file = try #require(entries["Größe ✓.txt"])
        #expect(file.isFile)
        #expect(file.logicalSize == 3_000)
        #expect(file.allocatedSize == fixture.allocatedSize("Größe ✓.txt"))
        #expect(file.linkCount == 1)
        #expect(try #require(entries["folder"]).isDirectory)
        #expect(try #require(entries["link"]).isSymlink)
    }
}
