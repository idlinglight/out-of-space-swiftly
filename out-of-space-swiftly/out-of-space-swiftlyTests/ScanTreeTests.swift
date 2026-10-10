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
