import CoreGraphics
import Foundation
import Testing
@testable import out_of_space_swiftly

/// Where the treemap outlines a selected item.
@MainActor
struct TreemapDrawingTests {
    private let size = CGSize(width: 160, height: 120)

    private func drawing(of fixture: FixtureTree, size: CGSize? = nil) async -> (ScanTree, TreemapDrawing) {
        let tree = await Scan(root: fixture.root, options: .fixture).run().tree
        return (tree, TreemapDrawing(tree: tree, key: .init(version: 0, zoom: tree.root, size: size ?? self.size)))
    }

    @Test func anItemTooSmallForATileIsOutlinedByItsSmallerItemsTile() async throws {
        let fixture = try FixtureTree()
        try fixture.file("folder/big1.bin", size: 4_000_000)
        try fixture.file("folder/big2.bin", size: 4_000_000)
        try fixture.file("folder/tiny.bin", size: 4_000)
        try fixture.file("other.bin", size: 4_000_000)
        try fixture.file("small.bin", size: 4_000)
        let (tree, drawing) = await drawing(of: fixture)
        let folder = try #require(tree.node(atRelativePath: "folder"))
        let big = try #require(tree.node(atRelativePath: "folder/big1.bin"))
        let tiny = try #require(tree.node(atRelativePath: "folder/tiny.bin"))
        let small = try #require(tree.node(atRelativePath: "small.bin"))
        let folderTile = try #require(drawing.tileIndex[folder])
        let folderRemainder = try #require(drawing.remainderIndex[folder])
        let rootRemainder = try #require(drawing.remainderIndex[tree.root])

        let bigOutline = try #require(drawing.outline(for: big, in: tree))
        #expect(bigOutline.isExact)

        // Inside a folder: the folder's "smaller items" tile, not the whole folder.
        let tinyOutline = try #require(drawing.outline(for: tiny, in: tree))
        #expect(!tinyOutline.isExact)
        #expect(tinyOutline.rect == drawing.layout.tiles[folderRemainder].rect)
        #expect(tinyOutline.rect != drawing.layout.tiles[folderTile].rect)

        // At the zoom level itself: the zoom level's "smaller items" tile, not the whole treemap.
        let smallOutline = try #require(drawing.outline(for: small, in: tree))
        #expect(!smallOutline.isExact)
        #expect(smallOutline.rect == drawing.layout.tiles[rootRemainder].rect)
    }

    @Test func anItemWithNoAreaAtTheZoomLevelGetsNoOutline() async throws {
        let fixture = try FixtureTree()
        try fixture.file("big.bin", size: 4_000_000)
        try fixture.file("empty.txt", size: 0)
        let (tree, drawing) = await drawing(of: fixture)
        let empty = try #require(tree.node(atRelativePath: "empty.txt"))

        #expect(drawing.outline(for: empty, in: tree) == nil)
    }

    @Test func anItemInAFolderDrawnAsOneBlockIsOutlinedByThatBlock() async throws {
        let fixture = try FixtureTree()
        // On a 9-point canvas the folder's padded content is narrower than the minimum side, so it is drawn
        // as one block; "outer" holds only "inner", so the two fold into one tile.
        try fixture.file("outer/inner/a.bin", size: 12_000)
        try fixture.file("outer/inner/b.bin", size: 12_000)
        let (tree, drawing) = await drawing(of: fixture, size: CGSize(width: 9, height: 9))
        let outer = try #require(tree.node(atRelativePath: "outer"))
        let inner = try #require(tree.node(atRelativePath: "outer/inner"))
        let file = try #require(tree.node(atRelativePath: "outer/inner/a.bin"))
        let block = try #require(drawing.tileIndex[inner])
        try #require(drawing.layout.tiles[block].isCutOff)

        #expect(drawing.tileIndex[outer] == block, "the folded chain shares one tile")
        let outerOutline = try #require(drawing.outline(for: outer, in: tree))
        #expect(outerOutline.isExact)
        let fileOutline = try #require(drawing.outline(for: file, in: tree))
        #expect(!fileOutline.isExact)
        #expect(fileOutline.rect == drawing.layout.tiles[block].rect)
    }
}
