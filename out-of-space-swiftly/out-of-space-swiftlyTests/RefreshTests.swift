import Foundation
import Testing
@testable import out_of_space_swiftly

/// How a window decides what to bring up to date after file system events.
@MainActor
struct RefreshTests {
    @Test func aFolderComesBeforeTheFoldersInsideIt() {
        let changes = ScanWindowModel.coalesce(["a/b": false, "a": false, "c": false])
        #expect(changes.map(\.path) == ["a", "a/b", "c"])
    }

    @Test func aDeepRescanCoversEverythingBelowIt() {
        let changes = ScanWindowModel.coalesce(["a": true, "a/b": false, "a/b/c": true, "ab": false])
        #expect(changes.map(\.path) == ["a", "ab"])
        #expect(changes.first?.deep == true)
        #expect(ScanWindowModel.coalesce(["": true, "x": false]).map(\.path) == [""])
    }

    @Test func aChangeMapsToTheNearestEnteredFolder() async throws {
        let fixture = try FixtureTree()
        try fixture.file("Users/me/Downloads/file.bin", size: 1_000)
        try fixture.file("Users/me/note.txt", size: 100)
        let tree = await Scan(root: fixture.root, options: .fixture).run().tree
        let downloads = try #require(tree.node(atRelativePath: "Users/me/Downloads"))
        let me = try #require(tree.node(atRelativePath: "Users/me"))

        #expect(ScanWindowModel.refreshTarget(for: "Users/me/Downloads", in: tree, rootPath: fixture.root.path) == .directory(downloads))
        #expect(ScanWindowModel.refreshTarget(for: "Users/me/Gone/deeper", in: tree, rootPath: fixture.root.path) == .directory(me))
        #expect(ScanWindowModel.refreshTarget(for: "", in: tree, rootPath: fixture.root.path) == .directory(tree.root))
    }

    @Test func changesInsideFoldersTheScanDidNotLookIntoAreLeftAlone() async throws {
        let fixture = try FixtureTree()
        try fixture.file("Library/Containers/app/Data/file.bin", size: 1_000)
        try fixture.file("Library/locked/file.bin", size: 1_000)
        try fixture.setPermissions("Library/locked", 0)
        try fixture.file("Library/cloud/file.bin", size: 1_000)
        var options = ScanOptions.fixture
        options.protectedPaths = [fixture.url("Library/Containers").path]
        let tree = await Scan(root: fixture.root, options: options).run().tree
        let library = try #require(tree.node(atRelativePath: "Library"))
        let locked = try #require(tree.node(atRelativePath: "Library/locked"))
        // A fixture cannot make a folder cloud-only; the tree is told so instead.
        let cloud = try #require(tree.node(atRelativePath: "Library/cloud"))
        tree.update(cloud) { $0.flags.formUnion([.notEntered, .dataless]) }
        let root = fixture.root.path

        #expect(ScanWindowModel.refreshTarget(for: "Library/Containers", in: tree, rootPath: root) == .unseen)
        #expect(ScanWindowModel.refreshTarget(for: "Library/Containers/app/Data", in: tree, rootPath: root) == .unseen)
        #expect(ScanWindowModel.refreshTarget(for: "Library/locked/new/deeper", in: tree, rootPath: root) == .unseen)
        // The folder that could not be opened is listed again for a change of its own (its permissions).
        #expect(ScanWindowModel.refreshTarget(for: "Library/locked", in: tree, rootPath: root) == .directory(locked))
        // A cloud-only folder being downloaded is found by listing the folder that holds it.
        #expect(ScanWindowModel.refreshTarget(for: "Library/cloud/sub", in: tree, rootPath: root) == .directory(library))
        // Such folders appearing or going away are reported for the folder that holds them.
        #expect(ScanWindowModel.refreshTarget(for: "Library", in: tree, rootPath: root) == .directory(library))
    }

    @Test func anUpdateKeepsHoverAndSelectionOnTheirItems() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a/one.bin", size: 40_000)
        try fixture.file("b/two.bin", size: 20_000)
        let model = ScanWindowModel()
        model.scanOptions = .fixture
        defer { model.close() }
        model.start(ScanTarget(path: fixture.root.path))
        let deadline = ContinuousClock.now + .seconds(10)
        while model.phase != .finished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let tree = try #require(model.tree)
        let a = try #require(tree.node(atRelativePath: "a"))
        model.hovered = a
        model.selection = tree.node(atRelativePath: "b")

        // Listing the root again gives the folders in it new IDs.
        var options = ScanOptions.fixture
        options.descends = false
        let listing = await Scan(root: fixture.root, options: options).run().tree
        model.updateTree { current in
            current.refresh(current.root, listing: listing, subtrees: [:])
            return current
        }

        let hovered = try #require(model.hovered)
        #expect(hovered != a)
        #expect(tree.relativePath(of: hovered) == "a")
        #expect(model.selection.map { tree.relativePath(of: $0) } == "b")
    }

    @Test func dataVolumePathsMapToTheirFirmlinkedPlaceForTheStartupDisk() async throws {
        let fixture = try FixtureTree()
        try fixture.file("Users/me/Downloads/file.bin", size: 1_000)
        let tree = await Scan(root: fixture.root, options: .fixture).run().tree
        let downloads = try #require(tree.node(atRelativePath: "Users/me/Downloads"))

        // The tree stands in for a scan of `/`, as only the root path decides the mapping.
        #expect(ScanWindowModel.refreshTarget(for: "System/Volumes/Data/Users/me/Downloads", in: tree, rootPath: "/") == .directory(downloads))
        #expect(ScanWindowModel.refreshTarget(for: "System/Volumes/Data/Users/me/Downloads", in: tree, rootPath: fixture.root.path)
            == .directory(tree.root))
    }
}
