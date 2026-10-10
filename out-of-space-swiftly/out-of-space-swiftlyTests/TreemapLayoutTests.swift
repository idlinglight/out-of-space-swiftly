import CoreGraphics
import Foundation
import Testing
@testable import out_of_space_swiftly

// MARK: - Helpers

/// SplitMix64, so random inputs are the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Weights spread over several orders of magnitude, like file sizes.
private func spreadWeights(count: Int, using generator: inout SeededGenerator) -> [Double] {
    (0..<count).map { _ in exp(Double.random(in: 0..<12, using: &generator)) }
}

private func area(_ rect: CGRect) -> Double { Double(rect.width * rect.height) }

private func aspectRatio(_ rect: CGRect) -> Double { Double(max(rect.width / rect.height, rect.height / rect.width)) }

private func isInside(_ rect: CGRect, _ bounds: CGRect, tolerance: Double = 1e-9) -> Bool {
    rect.minX >= bounds.minX - tolerance && rect.minY >= bounds.minY - tolerance
        && rect.maxX <= bounds.maxX + tolerance && rect.maxY <= bounds.maxY + tolerance
}

/// Pairs of rects that overlap by more than `tolerance` in area; sweeps along x so thousands of rects stay cheap.
private func overlappingPairs(_ rects: [CGRect], tolerance: Double = 1e-8) -> Int {
    let boxes = rects.filter { $0.width > 0 && $0.height > 0 }
        .map { (minX: Double($0.minX), maxX: Double($0.maxX), minY: Double($0.minY), maxY: Double($0.maxY)) }
        .sorted { $0.minX < $1.minX }
    var count = 0
    for i in boxes.indices {
        let a = boxes[i]
        var j = i + 1
        while j < boxes.count, boxes[j].minX < a.maxX {
            let b = boxes[j]
            let width = min(a.maxX, b.maxX) - b.minX
            let height = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            if width > 0, height > 0, width * height > tolerance { count += 1 }
            j += 1
        }
    }
    return count
}

/// Slices the rect into strips along its longer side, for comparison.
private func sliceAndDice(_ weights: [Double], in rect: CGRect) -> [CGRect] {
    let total = weights.reduce(0, +)
    var offset = 0.0
    return weights.map { weight in
        let share = weight / total
        defer { offset += share }
        return rect.width >= rect.height
            ? CGRect(x: rect.minX + rect.width * offset, y: rect.minY, width: rect.width * share, height: rect.height)
            : CGRect(x: rect.minX, y: rect.minY + rect.height * offset, width: rect.width, height: rect.height * share)
    }
}

/// A tree described by children lists, ids are Ints; the root is id 0.
private struct TestTree {
    var children: [Int: [TreemapItem<Int>]] = [:]
    func items(of id: Int) -> [TreemapItem<Int>] { children[id] ?? [] }

    var root: TreemapItem<Int> {
        TreemapItem(id: 0, weight: items(of: 0).reduce(0) { $0 + $1.weight }, isContainer: true)
    }

    func layout(in rect: CGRect, style: TreemapStyle) -> TreemapLayout<Int> {
        TreemapLayout(root: root, in: rect, style: style, children: items(of:))
    }

    /// A random tree: the root has `fanOut` children, other containers 0...`fanOut`; one in six children is a
    /// container, down to `depth` levels.
    static func random(seed: UInt64, depth: Int, fanOut: Int) -> TestTree {
        var generator = SeededGenerator(seed: seed)
        var tree = TestTree()
        var nextID = 1
        func fill(_ id: Int, level: Int) -> Double {
            var items: [TreemapItem<Int>] = []
            for _ in 0..<(level == 1 ? fanOut : Int.random(in: 0...fanOut, using: &generator)) {
                let child = nextID
                nextID += 1
                if level < depth, Int.random(in: 0..<6, using: &generator) == 0 {
                    items.append(TreemapItem(id: child, weight: fill(child, level: level + 1), isContainer: true))
                } else {
                    let weight = Int.random(in: 0..<20, using: &generator) == 0
                        ? 0 : exp(Double.random(in: 0..<14, using: &generator))
                    items.append(TreemapItem(id: child, weight: weight, isContainer: false))
                }
            }
            tree.children[id] = items
            return items.reduce(0) { $0 + $1.weight }
        }
        _ = fill(0, level: 1)
        return tree
    }
}

// MARK: - Flat squarified layout

struct SquarifiedLayoutTests {
    @Test(arguments: 1...12 as ClosedRange<UInt64>)
    func randomWeightsFillTheRectInProportion(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        let weights = spreadWeights(count: Int.random(in: 1...400, using: &generator), using: &generator)
        let bounds = CGRect(x: 10, y: 20, width: Double.random(in: 40...2000, using: &generator),
                            height: Double.random(in: 40...2000, using: &generator))
        let rects = SquarifiedLayout.rects(for: weights, in: bounds)
        let total = weights.reduce(0, +)

        #expect(rects.count == weights.count)
        #expect(rects.allSatisfy { isInside($0, bounds) })
        let misproportioned = zip(weights, rects).filter { abs(area($1) - area(bounds) * $0 / total) > 1e-9 * area(bounds) }
        #expect(misproportioned.isEmpty)
        #expect(abs(rects.reduce(0) { $0 + area($1) } - area(bounds)) <= 1e-9 * area(bounds))
        #expect(overlappingPairs(rects) == 0)
        #expect(SquarifiedLayout.rects(for: weights, in: bounds) == rects)
    }

    @Test func resultIsInInputOrder() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let rects = SquarifiedLayout.rects(for: [1, 4, 2, 3], in: bounds)
        #expect(rects.map(area) == [6000, 24000, 12000, 18000].map { Double($0) })

        // Distinct weights land in the same place whatever order they come in.
        var generator = SeededGenerator(seed: 7)
        let weights = spreadWeights(count: 60, using: &generator)
        let shuffled = Array(weights.indices).shuffled(using: &generator)
        let reordered = SquarifiedLayout.rects(for: shuffled.map { weights[$0] }, in: bounds)
        let original = SquarifiedLayout.rects(for: weights, in: bounds)
        #expect(shuffled.enumerated().allSatisfy { reordered[$0.offset] == original[$0.element] })
    }

    @Test func emptyInputGivesNoRects() {
        #expect(SquarifiedLayout.rects(for: [], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
    }

    @Test func oneWeightFillsTheRect() {
        let bounds = CGRect(x: 3, y: 4, width: 50, height: 7)
        #expect(SquarifiedLayout.rects(for: [42], in: bounds) == [bounds])
    }

    @Test func zeroAndUnusableWeightsGetZeroSize() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        let allZero = SquarifiedLayout.rects(for: [0, 0, 0], in: bounds)
        #expect(allZero.count == 3)
        #expect(allZero.allSatisfy { $0.size == .zero })

        let mixed = SquarifiedLayout.rects(for: [0, 3, -1, .nan, 1, .infinity], in: bounds)
        #expect([0, 2, 3, 5].allSatisfy { mixed[$0].size == .zero })
        #expect(area(mixed[1]) == 3750)
        #expect(area(mixed[4]) == 1250)
    }

    @Test func rectWithoutAreaGivesZeroSizes() {
        for bounds in [CGRect(x: 5, y: 5, width: 0, height: 100), .zero, .null] {
            let rects = SquarifiedLayout.rects(for: [1, 2, 3], in: bounds)
            #expect(rects.count == 3)
            #expect(rects.allSatisfy { $0.size == .zero })
        }
    }

    @Test func oneHugeWeightAmongThousandsOfTinyOnes() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let weights = [1e9] + Array(repeating: 1.0, count: 3000)
        let rects = SquarifiedLayout.rects(for: weights, in: bounds)
        let total = weights.reduce(0, +)

        #expect(rects.allSatisfy { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite })
        #expect(rects.allSatisfy { isInside($0, bounds) })
        #expect(abs(area(rects[0]) - area(bounds) * 1e9 / total) <= 1e-9 * area(bounds))
        let tiny = rects.dropFirst().map(area)
        #expect(tiny.allSatisfy { $0 > 0 })
        #expect(abs(tiny.reduce(0, +) - area(bounds) * 3000 / total) <= 1e-9 * area(bounds))
        #expect(overlappingPairs(rects) == 0)
    }

    /// Plain squarify puts the heavy weight in a row with 22 light ones, 1.9 points wide. With a minimum side the
    /// heavy one keeps a row of its own, the light ones get rows that fit, and what does not fit is left over.
    @Test func minimumSideTrimsRowsAndLeavesTheRest() {
        let weights = [600.0] + Array(repeating: 20.0, count: 200)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 1000)
        let tail = 100_000 - 4600.0
        let plain = SquarifiedLayout.layout(sortedWeights: weights, tail: tail, in: bounds)
        #expect(plain.rects.count == weights.count)
        #expect(plain.rects.contains { min($0.width, $0.height) < 4 })

        let fitted = SquarifiedLayout.layout(sortedWeights: weights, tail: tail, minimumSide: 4, in: bounds)
        #expect(fitted.rects.first == CGRect(x: 0, y: 0, width: 100, height: 6))
        #expect(fitted.rects.count == 199)
        #expect(fitted.rects.allSatisfy { min($0.width, $0.height) >= 4 - 1e-9 })
        #expect(abs(area(fitted.leftover) - (tail + 2 * 20)) < 1e-6)
        #expect(abs(fitted.leftover.maxY - 1000) < 1e-9)
    }

    @Test func aspectRatiosAreFarBetterThanSliceAndDice() {
        var generator = SeededGenerator(seed: 2000)
        let weights = spreadWeights(count: 200, using: &generator)
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        func mean(_ rects: [CGRect]) -> Double { rects.reduce(0) { $0 + aspectRatio($1) } / Double(rects.count) }

        let squarified = mean(SquarifiedLayout.rects(for: weights, in: bounds))
        let sliced = mean(sliceAndDice(weights, in: bounds))
        #expect(squarified < 3)
        #expect(squarified * 20 < sliced)
    }
}

// MARK: - Nested layout

struct TreemapLayoutTests {
    let bare = TreemapStyle(padding: 0, headerHeight: 0, minimumSide: 0)

    @Test func childrenFillTheRoot() {
        var tree = TestTree()
        tree.children[0] = [TreemapItem(id: 1, weight: 6, isContainer: false),
                            TreemapItem(id: 2, weight: 3, isContainer: false),
                            TreemapItem(id: 3, weight: 1, isContainer: false)]
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let tiles = tree.layout(in: bounds, style: bare).tiles

        #expect(tiles.count == 4)
        #expect(tiles[0].rect == bounds && tiles[0].isSubdivided && tiles[0].header == nil)
        #expect(tiles[0].children == 1..<4)
        #expect(tiles.dropFirst().map(\.id) == [1, 2, 3])
        #expect(tiles.dropFirst().allSatisfy { $0.parent == 0 && $0.depth == 1 && $0.kind == .leaf })
        #expect(tiles.dropFirst().map { area($0.rect) } == [6000, 3000, 1000])
    }

    @Test func leafRootIsOneTile() {
        let layout = TreemapLayout(root: TreemapItem(id: 9, weight: 5, isContainer: false),
                                   in: CGRect(x: 0, y: 0, width: 10, height: 10)) { _ in
            Issue.record("A leaf has no children to ask for")
            return []
        }
        #expect(layout.tiles.count == 1)
        #expect(layout.tiles[0].kind == .leaf)
    }

    @Test func emptyContainerAndEmptyRect() {
        let empty = TestTree().layout(in: CGRect(x: 0, y: 0, width: 10, height: 10), style: TreemapStyle())
        #expect(empty.tiles.count == 1)
        #expect(empty.tiles[0].isSubdivided && empty.tiles[0].children.isEmpty)

        var tree = TestTree()
        tree.children[0] = [TreemapItem(id: 1, weight: 1, isContainer: false)]
        let squashed = tree.layout(in: CGRect(x: 0, y: 0, width: 0, height: 10), style: TreemapStyle())
        #expect(squashed.tiles.count == 1)
        #expect(squashed.tiles[0].kind == .cutOff(.tooSmall))
    }

    /// A is 360 × 100 and gets a header; B is 40 × 100, too narrow for one.
    @Test func paddingAndHeaderShapeTheContent() throws {
        var tree = TestTree()
        tree.children[0] = [TreemapItem(id: 1, weight: 9, isContainer: true),
                            TreemapItem(id: 2, weight: 1, isContainer: true)]
        tree.children[1] = [TreemapItem(id: 11, weight: 1, isContainer: false),
                            TreemapItem(id: 12, weight: 1, isContainer: false)]
        tree.children[2] = [TreemapItem(id: 21, weight: 1, isContainer: false)]
        let style = TreemapStyle(padding: 3, headerHeight: 14, minimumHeaderWidth: 40, minimumSide: 4)
        let tiles = tree.layout(in: CGRect(x: 0, y: 0, width: 400, height: 100), style: style).tiles

        let a = try #require(tiles.first { $0.id == 1 })
        #expect(a.rect == CGRect(x: 0, y: 0, width: 360, height: 100))
        #expect(a.header == CGRect(x: 3, y: 3, width: 354, height: 14))
        let aChildren = tiles[a.children]
        #expect(aChildren.map(\.rect) == [CGRect(x: 3, y: 17, width: 177, height: 80),
                                          CGRect(x: 180, y: 17, width: 177, height: 80)])

        let b = try #require(tiles.first { $0.id == 2 })
        #expect(b.rect == CGRect(x: 360, y: 0, width: 40, height: 100))
        #expect(b.header == nil)
        #expect(tiles[b.children].map(\.rect) == [CGRect(x: 363, y: 3, width: 34, height: 94)])
    }

    @Test func containersTooSmallForTheirPaddingAreNotSubdivided() {
        var tree = TestTree()
        tree.children[0] = [TreemapItem(id: 1, weight: 1, isContainer: true)]
        tree.children[1] = [TreemapItem(id: 2, weight: 1, isContainer: false)]
        var asked: [Int] = []
        let style = TreemapStyle(padding: 2, headerHeight: 0, minimumSide: 5)
        let layout = TreemapLayout(root: tree.root, in: CGRect(x: 0, y: 0, width: 8, height: 8), style: style) {
            asked.append($0)
            return tree.items(of: $0)
        }

        // The child fills the 8 × 8 root, but 2 points of padding leave only 4 × 4 inside it.
        #expect(layout.tiles.map(\.kind) == [.subdivided, .cutOff(.tooSmall)])
        #expect(asked == [0])
    }

    @Test func depthLimitStopsSubdividing() {
        var tree = TestTree()
        for id in 0..<4 {
            tree.children[id] = [TreemapItem(id: id + 1, weight: 1, isContainer: id + 1 < 4)]
        }
        var asked: [Int] = []
        let style = TreemapStyle(padding: 1, headerHeight: 0, minimumSide: 1, maximumDepth: 2)
        let layout = TreemapLayout(root: tree.root, in: CGRect(x: 0, y: 0, width: 100, height: 100), style: style) {
            asked.append($0)
            return tree.items(of: $0)
        }

        #expect(layout.tiles.map(\.id) == [0, 1, 2])
        #expect(layout.tiles.map(\.kind) == [.subdivided, .subdivided, .cutOff(.depthLimit)])
        #expect(asked == [0, 1])
    }

    @Test func smallChildrenBecomeOneRemainder() throws {
        var tree = TestTree()
        tree.children[0] = [TreemapItem(id: 1, weight: 1000, isContainer: false)]
            + (2..<502).map { TreemapItem(id: $0, weight: 0.01, isContainer: false) }
            + (502..<512).map { TreemapItem(id: $0, weight: 0, isContainer: true) }
            + [TreemapItem(id: 512, weight: 1000, isContainer: true)]
        let style = TreemapStyle(padding: 0, headerHeight: 0, minimumSide: 4)
        let tiles = tree.layout(in: CGRect(x: 0, y: 0, width: 200, height: 100), style: style).tiles

        let children = tiles[tiles[0].children]
        #expect(children.map(\.id) == [1, 512, 0])
        let remainder = try #require(children.last)
        #expect(remainder.kind == .remainder(count: 510))
        #expect(abs(remainder.weight - 5) < 1e-9)
        #expect(abs(area(remainder.rect) - 20000 * 5 / 2005) < 1e-6)
        // It takes the space left at the end: the bottom right.
        #expect(abs(remainder.rect.maxX - 200) < 1e-9 && abs(remainder.rect.maxY - 100) < 1e-9)
    }

    /// Structure, geometry and accounting of a random tree, with a style that has every rule in play.
    @Test(arguments: 1...6 as ClosedRange<UInt64>)
    func randomTreeKeepsItsInvariants(seed: UInt64) {
        let tree = TestTree.random(seed: seed, depth: 6, fanOut: 40)
        let style = TreemapStyle(padding: 2, headerHeight: 14, minimumHeaderWidth: 40, minimumSide: 4, maximumDepth: 5)
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let tiles = tree.layout(in: bounds, style: style).tiles
        // The tree is big enough for every rule to apply somewhere.
        #expect(tiles.contains { $0.isRemainder })
        #expect(tiles.contains { $0.header != nil })
        #expect(tiles.contains { $0.kind == .cutOff(.tooSmall) })
        #expect(tiles.contains { $0.kind == .cutOff(.depthLimit) })

        #expect(tiles.first?.rect == bounds)
        #expect(tree.layout(in: bounds, style: style).tiles == tiles)
        for (index, tile) in tiles.enumerated() {
            #expect(tile.depth <= style.maximumDepth)
            if let parent = tile.parent {
                #expect(parent < index)
                #expect(tiles[parent].children.contains(index))
                #expect(tile.depth == tiles[parent].depth + 1)
                if !tile.isRemainder {
                    #expect(min(tile.rect.width, tile.rect.height) >= style.minimumSide - 1e-9)
                }
            }
            guard tile.isSubdivided else {
                #expect(tile.children.isEmpty)
                continue
            }

            let content = index == 0 ? tile.rect : style.frame(of: tile.rect).content
            let children = tiles[tile.children]
            #expect(children.allSatisfy { tiles[$0.parent!].id == tile.id && isInside($0.rect, content) })
            #expect(overlappingPairs(children.map(\.rect)) == 0)
            if let header = tile.header {
                #expect(header.maxY <= content.minY)
            }

            // Every child is accounted for: as a tile of its own or in the remainder.
            let items = tree.items(of: tile.id)
            let itemWeight = items.reduce(0) { $0 + SquarifiedLayout.usable($1.weight) }
            let tileWeight = children.reduce(0) { $0 + $1.weight }
            #expect(abs(itemWeight - tileWeight) <= 1e-9 * max(itemWeight, 1))
            let remainderCount = children.reduce(0) { if case .remainder(let count) = $1.kind { $0 + count } else { $0 } }
            #expect(children.filter { !$0.isRemainder }.count + remainderCount == items.count)
            #expect(children.filter(\.isRemainder).count <= 1)
            if itemWeight > 0 {
                #expect(abs(children.reduce(0) { $0 + area($1.rect) } - area(content)) <= 1e-6 * area(content))
            }
        }
    }

    @Test func tileCapLeavesTheRestCutOff() {
        let tree = TestTree.random(seed: 3, depth: 6, fanOut: 40)
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let unlimited = tree.layout(in: bounds, style: TreemapStyle())
        let capped = tree.layout(in: bounds, style: TreemapStyle(maximumTileCount: 100))

        #expect(unlimited.tiles.count > 100)
        #expect(capped.tiles.count <= 100)
        #expect(capped.tiles.contains { $0.kind == .cutOff(.tileLimit) })
        // Up to the cap, the same tiles in the same places.
        #expect(zip(capped.tiles, unlimited.tiles).allSatisfy { $0.id == $1.id && $0.rect == $1.rect })
    }

    /// About 200,000 files: one flat folder of 20,000, the rest in 39 folders of 50 subfolders each. The time is
    /// attached to the test result; the bound is loose so slow CI machines do not fail it.
    @Test func layoutOf200kLeavesIsFast() {
        var generator = SeededGenerator(seed: 200_000)
        var tree = TestTree()
        var nextID = 1
        var leafCount = 0
        func newID() -> Int {
            defer { nextID += 1 }
            return nextID
        }
        func addLeaves(to folder: Int, count: Int) -> TreemapItem<Int> {
            let leaves = (0..<count).map { _ in
                TreemapItem(id: newID(), weight: exp(Double.random(in: 0..<16, using: &generator)), isContainer: false)
            }
            leafCount += leaves.count
            tree.children[folder] = leaves
            return TreemapItem(id: folder, weight: leaves.reduce(0) { $0 + $1.weight }, isContainer: true)
        }
        var top = [addLeaves(to: newID(), count: 20_000)]
        for _ in 0..<39 {
            let folder = newID()
            let subfolders = (0..<50).map { _ in addLeaves(to: newID(), count: Int.random(in: 1...183, using: &generator)) }
            tree.children[folder] = subfolders
            top.append(TreemapItem(id: folder, weight: subfolders.reduce(0) { $0 + $1.weight }, isContainer: true))
        }
        tree.children[0] = top

        let bounds = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        var tileCount = 0
        let elapsed = ContinuousClock().measure {
            tileCount = tree.layout(in: bounds, style: TreemapStyle()).tiles.count
        }
        let milliseconds = Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15
        Attachment.record("\(leafCount) leaves, \(tileCount) tiles, \(String(format: "%.1f", milliseconds)) ms",
                          named: "treemap-layout-time.txt")
        #expect(leafCount > 190_000)
        #expect(elapsed < .seconds(1))
    }
}

// MARK: - Hit testing

struct TreemapHitTestingTests {
    /// Root 400 × 100: A at 0...360 with a header and children at x 3...180 and 180...357; B at 360...400.
    let layout: TreemapLayout<Int> = {
        var tree = TestTree()
        tree.children[0] = [TreemapItem(id: 1, weight: 9, isContainer: true),
                            TreemapItem(id: 2, weight: 1, isContainer: true)]
        tree.children[1] = [TreemapItem(id: 11, weight: 1, isContainer: false),
                            TreemapItem(id: 12, weight: 1, isContainer: false)]
        tree.children[2] = [TreemapItem(id: 21, weight: 1, isContainer: false)]
        let style = TreemapStyle(padding: 3, headerHeight: 14, minimumHeaderWidth: 40, minimumSide: 4)
        return tree.layout(in: CGRect(x: 0, y: 0, width: 400, height: 100), style: style)
    }()

    @Test(arguments: [
        (CGPoint(x: 50, y: 50), 11),  // inside a nested leaf
        (CGPoint(x: 179.999, y: 50), 11),
        (CGPoint(x: 180, y: 50), 12),  // the edge two siblings share belongs to the right one
        (CGPoint(x: 50, y: 10), 1),  // header
        (CGPoint(x: 1, y: 50), 1),  // padding
        (CGPoint(x: 0, y: 0), 1),  // top left corner of the root
        (CGPoint(x: 360, y: 50), 2),  // left edge of B, in its padding
        (CGPoint(x: 380, y: 50), 21),
        (CGPoint(x: 399.999, y: 99.999), 2),
    ])
    func findsTheDeepestTile(point: CGPoint, id: Int) {
        #expect(layout.tile(at: point)?.id == id)
    }

    @Test(arguments: [CGPoint(x: 400, y: 50), CGPoint(x: 50, y: 100), CGPoint(x: -0.001, y: 0), CGPoint(x: 1000, y: 1000)])
    func pointsOutsideHitNothing(point: CGPoint) {
        #expect(layout.tileIndex(at: point) == nil)
    }

    @Test func agreesWithBruteForceOnARandomTree() {
        let tree = TestTree.random(seed: 11, depth: 6, fanOut: 40)
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let layout = tree.layout(in: bounds, style: TreemapStyle())
        var generator = SeededGenerator(seed: 12)
        for _ in 0..<200 {
            let point = CGPoint(x: Double.random(in: 0..<1200, using: &generator), y: Double.random(in: 0..<800, using: &generator))
            let containing = layout.tiles.filter { $0.rect.contains(point) }
            let hit = layout.tile(at: point)
            #expect(hit != nil && hit!.rect.contains(point))
            #expect(hit?.depth == containing.map(\.depth).max())
        }
    }
}
