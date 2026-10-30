import Foundation
import Testing
@testable import out_of_space_swiftly

/// Changes to a finished tree: removing an item, and grafting in a rescan of one folder.
struct ScanTreeTests {
    private func scan(_ url: URL) async -> ScanTree {
        await Scan(root: url, options: .fixture).run().tree
    }

    @Test func removingAnItemTakesItOutOfEveryTotal() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a/big.bin", size: 300_000)
        try fixture.file("a/small.bin", size: 10_000)
        try fixture.file("b/medium.bin", size: 100_000)
        let tree = await scan(fixture.root)
        let big = try #require(tree.node(atRelativePath: "a/big.bin"))
        let before = tree.size(of: tree.root)

        tree.remove(big)

        #expect(tree.size(of: tree.root) == before - fixture.allocatedSize("a/big.bin"))
        #expect(tree.flags(of: big).contains(.removed))
        #expect(tree.node(atRelativePath: "a/big.bin") == nil)
        #expect(tree.children(of: tree.root).map { tree.name(of: $0) } == ["b", "a"])
    }

    @Test func removingTheLastItemLeavesNoContainer() async throws {
        let fixture = try FixtureTree()
        try fixture.file("outer/inner/only.bin", size: 5_000)
        let tree = await scan(fixture.root)
        let outer = try #require(tree.node(atRelativePath: "outer"))
        let inner = try #require(tree.node(atRelativePath: "outer/inner"))
        #expect(tree.isContainer(outer))

        tree.remove(inner)

        #expect(!tree.isContainer(outer))
        #expect(tree.size(of: tree.root) == 0)
    }

    @Test func removedItemsSortLastAndCompactionDropsThem() async throws {
        let fixture = try FixtureTree()
        try fixture.file("a/big.bin", size: 200_000)
        try fixture.file("a/small.bin", size: 2_000)
        try fixture.file("b/mid.bin", size: 50_000)
        let tree = await scan(fixture.root)
        let a = try #require(tree.node(atRelativePath: "a"))
        tree.remove(try #require(tree.node(atRelativePath: "a/big.bin")))

        #expect(tree.children(of: a).map { tree.name(of: $0) } == ["small.bin"])
        #expect(tree.children(of: tree.root).map { tree.name(of: $0) } == ["b", "a"])
        let before = tree.size(of: tree.root)

        tree.compact()

        #expect(tree.count == tree.reachableCount)
        #expect(tree.size(of: tree.root) == before)
        #expect(tree.children(of: tree.root).map { tree.name(of: $0) } == ["b", "a"])
        let small = try #require(tree.node(atRelativePath: "a/small.bin"))
        #expect(tree.path(of: small) == fixture.url("a/small.bin").path)
        #expect(tree.node(atRelativePath: "a/big.bin") == nil)
    }

    @Test func refreshingOneLevelMatchesAFullScan() async throws {
        let fixture = try FixtureTree()
        try fixture.file("kept/deep/a.bin", size: 70_000)
        try fixture.file("gone/b.bin", size: 30_000)
        try fixture.file("top.bin", size: 10_000)
        let tree = await scan(fixture.root)
        let keptDeep = try #require(tree.node(atRelativePath: "kept/deep"))

        try FileManager.default.removeItem(at: fixture.url("gone"))
        try fixture.file("new/c.bin", size: 120_000)
        try fixture.file("added.bin", size: 4_000)
        var options = ScanOptions.fixture
        options.descends = false
        let listing = await Scan(root: fixture.root, options: options).run().tree
        #expect(listing.node(atRelativePath: "new/c.bin") == nil)
        let newFolder = await scan(fixture.url("new"))
        tree.refresh(tree.root, listing: listing, subtrees: ["new": newFolder])
        let fresh = await scan(fixture.root)

        #expect(tree.size(of: tree.root) == fresh.size(of: fresh.root))
        #expect(tree.node(tree.root).descendantCount == fresh.node(fresh.root).descendantCount)
        #expect(tree.children(of: tree.root).map { tree.name(of: $0) } == fresh.children(of: fresh.root).map { fresh.name(of: $0) })
        #expect(tree.node(atRelativePath: "gone") == nil)
        #expect(tree.node(atRelativePath: "kept/deep") == keptDeep, "the subtree below a kept folder keeps its IDs")
        let c = try #require(tree.node(atRelativePath: "new/c.bin"))
        #expect(tree.path(of: c) == fixture.url("new/c.bin").path)
        let kept = try #require(tree.node(atRelativePath: "kept"))
        #expect(tree.parent(of: keptDeep) == kept)
    }

    @Test func aListingTellsWhetherAnythingThatShowsChanged() async throws {
        let fixture = try FixtureTree()
        try fixture.file("folder/a.bin", size: 30_000)
        try fixture.file("folder/b.bin", size: 10_000)
        try fixture.file("folder/sub/c.bin", size: 5_000)
        try fixture.directory("folder/locked")
        try fixture.setPermissions("folder/locked", 0)
        var tree = await scan(fixture.root)
        func listingShowsTheSame() async throws -> Bool {
            let folder = try #require(tree.node(atRelativePath: "folder"))
            var options = ScanOptions.fixture
            options.descends = false
            return tree.hasSameEntries(folder, as: await Scan(root: fixture.url("folder"), options: options).run().tree)
        }

        // The folder that could not be read keeps its error: not something the listing sees.
        #expect(try await listingShowsTheSame())

        // A file rewritten as it was: a new file of the same size put in its place.
        let rewritten = try fixture.file("b.tmp", size: 10_000)
        #expect(rename(rewritten.path, fixture.url("folder/b.bin").path) == 0)
        #expect(try await listingShowsTheSame())

        try fixture.file("folder/a.bin", size: 60_000)
        #expect(try await !listingShowsTheSame(), "a file grew")
        tree = await scan(fixture.root)

        try fixture.file("folder/new.bin", size: 1_000)
        #expect(try await !listingShowsTheSame(), "a file was added")
        tree = await scan(fixture.root)

        try FileManager.default.removeItem(at: fixture.url("folder/b.bin"))
        #expect(try await !listingShowsTheSame(), "a file went away")
        tree = await scan(fixture.root)

        try FileManager.default.removeItem(at: fixture.url("folder/sub"))
        try fixture.directory("folder/sub")
        #expect(try await !listingShowsTheSame(), "another folder of the same name")
    }

    @Test func aCloudOnlyFolderDownloadedSinceIsScannedAnew() async throws {
        let fixture = try FixtureTree()
        try fixture.file("cloud/file.bin", size: 50_000)
        try fixture.file("local.bin", size: 10_000)
        let tree = await scan(fixture.root)
        // A fixture cannot make a folder cloud-only; the tree is told it was one when it was scanned.
        let cloud = try #require(tree.node(atRelativePath: "cloud"))
        tree.update(cloud) { $0.flags.formUnion([.notEntered, .dataless]) }
        var options = ScanOptions.fixture
        options.descends = false
        let listing = await Scan(root: fixture.root, options: options).run().tree
        let entry = try #require(listing.node(atRelativePath: "cloud"))

        #expect(!tree.keepsSubtree(of: cloud, for: listing.node(entry)))
        #expect(!tree.hasSameEntries(tree.root, as: listing))
        tree.refresh(tree.root, listing: listing, subtrees: ["cloud": await scan(fixture.url("cloud"))])
        let fresh = await scan(fixture.root)
        let downloaded = try #require(tree.node(atRelativePath: "cloud"))
        #expect(!tree.flags(of: downloaded).contains(.dataless))
        #expect(tree.node(atRelativePath: "cloud/file.bin") != nil)
        #expect(tree.size(of: tree.root) == fresh.size(of: fresh.root))
    }

    @Test func aFolderThatStillCannotBeReadShowsTheSame() async throws {
        let fixture = try FixtureTree()
        try fixture.file("locked/file.bin", size: 1_000)
        try fixture.setPermissions("locked", 0)
        let tree = await scan(fixture.root)
        let locked = try #require(tree.node(atRelativePath: "locked"))
        var options = ScanOptions.fixture
        options.descends = false
        let listing = await Scan(root: fixture.url("locked"), options: options).run().tree

        #expect(listing.error(of: listing.root) != nil)
        #expect(tree.hasSameEntries(locked, as: listing))
    }

    @Test func graftingARescanMatchesAFullScan() async throws {
        let fixture = try FixtureTree()
        try fixture.file("docs/one.bin", size: 40_000)
        try fixture.file("docs/deep/two.bin", size: 20_000)
        try fixture.file("media/three.bin", size: 150_000)
        let tree = await scan(fixture.root)
        let docs = try #require(tree.node(atRelativePath: "docs"))

        try fixture.file("docs/deep/new.bin", size: 500_000)
        try FileManager.default.removeItem(at: fixture.url("docs/one.bin"))
        tree.graft(await scan(fixture.url("docs")), at: docs)
        let fresh = await scan(fixture.root)

        #expect(tree.size(of: tree.root) == fresh.size(of: fresh.root))
        #expect(tree.node(tree.root).descendantCount == fresh.node(fresh.root).descendantCount)
        #expect(tree.node(atRelativePath: "docs") == docs)
        #expect(tree.node(atRelativePath: "docs/one.bin") == nil)
        let new = try #require(tree.node(atRelativePath: "docs/deep/new.bin"))
        #expect(tree.path(of: new) == fixture.url("docs/deep/new.bin").path)
        #expect(tree.relativePath(of: new) == "docs/deep/new.bin")
        #expect(tree.children(of: tree.root).map { tree.name(of: $0) } == ["docs", "media"])
        for id in tree.lineage(of: new) where tree.node(id).childCount > 0 {
            let children = tree.children(of: id)
            #expect(tree.size(of: id) == children.reduce(0) { $0 + tree.size(of: $1) })
        }
    }
}
