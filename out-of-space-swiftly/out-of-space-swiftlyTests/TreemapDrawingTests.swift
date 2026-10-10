import CoreGraphics
import Foundation
import Testing
@testable import out_of_space_swiftly

/// Where the treemap outlines a selected or hovered item.
@MainActor
struct TreemapDrawingTests {
    @Test func anItemTooSmallForATileIsOutlinedByItsSmallerItemsTile() async throws {
        let fixture = try FixtureTree()
        try fixture.file("folder/big1.bin", size: 4_000_000)
        try fixture.file("folder/big2.bin", size: 4_000_000)
        try fixture.file("folder/tiny.bin", size: 4_000)
        try fixture.file("other.bin", size: 4_000_000)
        try fixture.file("small.bin", size: 4_000)
        let tree = await Scan(root: fixture.root, options: .fixture).run().tree
        let drawing = TreemapDrawing(tree: tree, key: .init(version: 0, zoom: tree.root, size: CGSize(width: 160, height: 120)))
        let folder = try #require(tree.node(atRelativePath: "folder"))
        let big = try #require(tree.node(atRelativePath: "folder/big1.bin"))
        let tiny = try #require(tree.node(atRelativePath: "folder/tiny.bin"))
        let small = try #require(tree.node(atRelativePath: "small.bin"))
        let folderTile = try #require(drawing.tileIndex[folder])
        let folderRemainder = try #require(drawing.remainderIndex[folder])

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
        #expect(smallOutline.rect.width < 160 && smallOutline.rect.height < 120)
    }
}
