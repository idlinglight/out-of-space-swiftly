import Foundation

/// Index of a node in a `ScanTree`. The root is 0.
typealias NodeID = Int32

/// The result of a scan: every file and directory under the root, in flat arrays.
///
/// A directory's children sit next to each other (`firstChild ..< firstChild + childCount`) and always after
/// their parent, so totals are summed in one backward pass. `children(of:)` hands them out largest first.
///
/// Ownership: the scanner mutates a tree under its own lock until the scan ends, then hands it over; from
/// then on it is read and changed on the main actor only. Hence `@unchecked Sendable`.
nonisolated final class ScanTree: @unchecked Sendable {
    enum Kind: UInt8, Sendable {
        case file, directory, symlink
        /// Device, socket or pipe.
        case other
        /// Another volume is mounted here; not entered.
        case mountPoint
        /// An automount trigger; not entered.
        case automount
        /// Made up by the scanner to group nodes, such as the folders found only on the Data volume.
        case group
    }

    struct Flags: OptionSet, Sendable {
        let rawValue: UInt16
        /// A directory the scanner did not enter; `Kind` or the other flags say why.
        static let notEntered = Flags(rawValue: 1 << 0)
        /// Left out on purpose because macOS protects it (other apps' containers).
        static let protected = Flags(rawValue: 1 << 1)
        /// Content lives in the cloud; not downloaded and not entered.
        static let dataless = Flags(rawValue: 1 << 2)
        /// The same directory was already counted under another path.
        static let alreadyCounted = Flags(rawValue: 1 << 3)
        static let sparse = Flags(rawValue: 1 << 4)
        static let compressed = Flags(rawValue: 1 << 5)
        static let purgeable = Flags(rawValue: 1 << 6)
        /// Shares some blocks with another file (a partial clone); counted in full.
        static let mayShareBlocks = Flags(rawValue: 1 << 7)
        /// Another link to this file, or another member of its full-clone set, was counted already.
        static let duplicate = Flags(rawValue: 1 << 8)
        static let firmlink = Flags(rawValue: 1 << 9)
        /// Reading this item failed (a directory: it could not be read, or not completely); see `error(of:)`.
        static let failed = Flags(rawValue: 1 << 10)
        /// Reading the directory took longer than the scan's patience.
        static let slow = Flags(rawValue: 1 << 11)
        /// A file with more than one link.
        static let hardLinked = Flags(rawValue: 1 << 12)
        /// A member of a full-clone set: shares all its blocks with other files.
        static let sharesAllBlocks = Flags(rawValue: 1 << 13)
        /// Moved to the Trash from the app; no longer in the totals or among its parent's children.
        static let removed = Flags(rawValue: 1 << 14)
    }

    struct Node: Sendable {
        var parent: NodeID
        var firstChild: NodeID = 0
        var childCount: Int32 = 0
        var kind: Kind
        var flags: Flags = []
        /// Bytes on disk of this file itself; 0 for directories.
        var allocatedSize: Int64 = 0
        var logicalSize: Int64 = 0
        /// What this node adds to the disk: its allocated size, or 0 for a duplicate; for a directory, the
        /// sum over everything below it. Final after `finish()`.
        var size: Int64 = 0
        /// Files and directories below this node. Final after `finish()`.
        var descendantCount: Int32 = 0
        /// Children moved to the Trash; they sit at the end of the sorted child block.
        var removedChildren: Int32 = 0
        var device: Int32 = 0
        var fileID: UInt64 = 0
        /// Same for all members of a set of clones; 0 if unknown.
        var cloneID: UInt64 = 0
    }

    private(set) var nodes: [Node] = []
    private(set) var names: [String] = []
    /// Nodes whose path does not follow from their parent's: the root, and groups such as the Data volume.
    private var basePaths: [NodeID: String] = [:]
    /// errno of directories that could not be read completely.
    private var errors: [NodeID: Int32] = [:]
    /// Children of each directory ordered by size, largest first, removed ones last; filled by `finish()`.
    private var sortedChildren: [NodeID] = []

    let rootPath: String
    let root: NodeID = 0

    init(rootPath: String, rootName: String, device: Int32, fileID: UInt64) {
        self.rootPath = rootPath
        nodes.append(Node(parent: -1, kind: .directory, device: device, fileID: fileID))
        names.append(rootName)
        basePaths[0] = rootPath
    }

    var count: Int { nodes.count }

    // MARK: Reading

    func node(_ id: NodeID) -> Node { nodes[Int(id)] }
    func name(of id: NodeID) -> String { names[Int(id)] }
    func kind(of id: NodeID) -> Kind { nodes[Int(id)].kind }
    func flags(of id: NodeID) -> Flags { nodes[Int(id)].flags }
    func size(of id: NodeID) -> Int64 { nodes[Int(id)].size }
    func parent(of id: NodeID) -> NodeID? { id == root ? nil : nodes[Int(id)].parent }
    func error(of id: NodeID) -> Int32? { errors[id] }

    /// Whether the node holds others: a directory that was entered, or a group, with children left.
    func isContainer(_ id: NodeID) -> Bool {
        let node = nodes[Int(id)]
        return (node.kind == .directory || node.kind == .group) && node.childCount - node.removedChildren > 0
    }

    /// The indices of a node's child block, removed children included.
    private func childRange(of id: NodeID) -> Range<Int> {
        let node = nodes[Int(id)]
        return Int(node.firstChild) ..< Int(node.firstChild) + Int(node.childCount)
    }

    /// The node's children, largest first once the tree is finished; in reading order before. Removed
    /// nodes are left out (they are sorted to the end of the block).
    func children(of id: NodeID) -> ArraySlice<NodeID> {
        let node = nodes[Int(id)]
        let first = Int(node.firstChild)
        guard sortedChildren.count == nodes.count else {
            return ArraySlice((first ..< first + Int(node.childCount)).map { NodeID($0) })
        }
        return sortedChildren[first ..< first + Int(node.childCount - node.removedChildren)]
    }

    /// Ancestors from the root down to the node itself.
    func lineage(of id: NodeID) -> [NodeID] {
        var chain = [id]
        var current = id
        while let parent = parent(of: current) {
            chain.append(parent)
            current = parent
        }
        return chain.reversed()
    }

    /// The node's location in the file system.
    func path(of id: NodeID) -> String {
        var components: [String] = []
        var current = id
        while basePaths[current] == nil {
            components.append(names[Int(current)])
            current = nodes[Int(current)].parent
        }
        var path = basePaths[current]!
        for component in components.reversed() {
            path += path.hasSuffix("/") ? component : "/" + component
        }
        return path
    }

    func url(of id: NodeID) -> URL {
        URL(fileURLWithPath: path(of: id), isDirectory: kind(of: id) == .directory)
    }

    // MARK: Building (scanner only)

    /// Appends a directory's entries as its children, next to each other. Returns the first new ID.
    @discardableResult
    func appendChildren(of parent: NodeID, _ children: [(name: String, node: Node)]) -> NodeID {
        let first = NodeID(nodes.count)
        nodes[Int(parent)].firstChild = first
        nodes[Int(parent)].childCount = Int32(children.count)
        for child in children {
            var node = child.node
            node.parent = parent
            nodes.append(node)
            names.append(child.name)
        }
        return first
    }

    /// Gives a node (a group) a path of its own instead of one below its parent.
    func setBasePath(_ path: String, for id: NodeID) {
        basePaths[id] = path
    }

    func update(_ id: NodeID, _ change: (inout Node) -> Void) {
        change(&nodes[Int(id)])
    }

    func setError(_ code: Int32, for id: NodeID) {
        errors[id] = code
        nodes[Int(id)].flags.insert(.failed)
    }

    /// Replaces everything below `target` with what a fresh scan of that directory found. `subtree` must be
    /// finished; its root stands for `target`, which keeps its name and place. The old nodes stay in the
    /// arrays, unreachable; IDs below `target` change.
    func graft(_ subtree: ScanTree, at target: NodeID) {
        graft(subtree, at: target, propagates: true)
    }

    private func graft(_ subtree: ScanTree, at target: NodeID, propagates: Bool) {
        precondition(sortedChildren.count == nodes.count && subtree.sortedChildren.count == subtree.nodes.count,
                     "both trees must be finished")
        let base = NodeID(nodes.count) - 1
        let replacement = subtree.nodes[0]
        let old = nodes[Int(target)]
        nodes.reserveCapacity(nodes.count + subtree.nodes.count - 1)
        for index in 1 ..< subtree.nodes.count {
            var node = subtree.nodes[index]
            node.parent = node.parent == 0 ? target : base + node.parent
            if node.childCount > 0 { node.firstChild = base + node.firstChild }
            nodes.append(node)
            names.append(subtree.names[index])
        }
        sortedChildren.append(contentsOf: subtree.sortedChildren.dropFirst().map { base + $0 })
        for (id, path) in subtree.basePaths where id != 0 { basePaths[base + id] = path }
        errors[target] = nil
        for (id, code) in subtree.errors { errors[id == 0 ? target : base + id] = code }
        nodes[Int(target)].firstChild = replacement.childCount > 0 ? base + replacement.firstChild : 0
        nodes[Int(target)].childCount = replacement.childCount
        nodes[Int(target)].removedChildren = replacement.removedChildren
        nodes[Int(target)].size = replacement.size
        nodes[Int(target)].descendantCount = replacement.descendantCount
        nodes[Int(target)].flags = replacement.flags.union(old.flags.intersection([.firmlink]))

        if propagates {
            propagate(from: target, size: replacement.size - old.size, count: replacement.descendantCount - old.descendantCount)
        }
    }

    /// Brings one directory up to date from `listing`, a finished one-level scan of it. Subdirectories that are
    /// still the same directory (name and file ID) keep their subtree; new ones take theirs from `subtrees`, by
    /// name; groups the scanner made up are kept; everything else comes from the listing. The directory's
    /// children get new IDs; the subtrees below kept subdirectories keep theirs.
    func refresh(_ target: NodeID, listing: ScanTree, subtrees: [String: ScanTree]) {
        precondition(sortedChildren.count == nodes.count && listing.sortedChildren.count == listing.nodes.count,
                     "both trees must be finished")
        let old = nodes[Int(target)]
        var kept: [String: NodeID] = [:]
        var groups: [NodeID] = []
        for child in childRange(of: target) where !nodes[child].flags.contains(.removed) {
            if nodes[child].kind == .directory { kept[names[child]] = NodeID(child) }
            if nodes[child].kind == .group { groups.append(NodeID(child)) }
        }

        let first = NodeID(nodes.count)
        var moved: [(from: NodeID, to: NodeID)] = []
        var grafts: [(NodeID, ScanTree)] = []
        func append(_ node: ScanTree.Node, named name: String) -> NodeID {
            let id = NodeID(nodes.count)
            var node = node
            node.parent = target
            nodes.append(node)
            names.append(name)
            sortedChildren.append(id)
            return id
        }
        for child in listing.childRange(of: listing.root) {
            let entry = listing.nodes[child]
            let name = listing.names[child]
            if entry.kind == .directory, !entry.flags.contains(.notEntered), let previous = kept[name],
               nodes[Int(previous)].fileID == entry.fileID {
                moved.append((previous, append(nodes[Int(previous)], named: name)))
                continue
            }
            let id = append(entry, named: name)
            if let code = listing.errors[NodeID(child)] { errors[id] = code }
            if entry.kind == .directory, !entry.flags.contains(.notEntered), let subtree = subtrees[name] {
                grafts.append((id, subtree))
            }
        }
        for group in groups {
            moved.append((group, append(nodes[Int(group)], named: names[Int(group)])))
        }
        nodes[Int(target)].firstChild = first
        nodes[Int(target)].childCount = NodeID(nodes.count) - first
        nodes[Int(target)].removedChildren = 0
        for (from, to) in moved {
            for child in childRange(of: to) { nodes[child].parent = to }
            if let code = errors.removeValue(forKey: from) { errors[to] = code }
            if let path = basePaths.removeValue(forKey: from) { basePaths[to] = path }
        }
        for (id, subtree) in grafts { graft(subtree, at: id, propagates: false) }

        errors[target] = listing.errors[listing.root]
        if errors[target] == nil { nodes[Int(target)].flags.remove(.failed) } else { nodes[Int(target)].flags.insert(.failed) }
        var size: Int64 = 0
        var count: Int32 = 0
        for child in childRange(of: target) where !nodes[child].flags.contains(.removed) {
            size += nodes[child].size
            count += nodes[child].descendantCount + 1
        }
        nodes[Int(target)].size = size
        nodes[Int(target)].descendantCount = count
        sortChildren(of: target)
        propagate(from: target, size: size - old.size, count: count - old.descendantCount)
    }

    /// Whether `listing`, a finished one-level scan of `target`, shows what the tree has there already: the
    /// same error, and the same entries by name, kind, flags and size on disk, folders by file ID. `refresh`
    /// would then change nothing that shows.
    func hasSameEntries(_ target: NodeID, as listing: ScanTree) -> Bool {
        guard errors[target] == listing.errors[listing.root] else { return false }
        var current: [String: NodeID] = [:]
        for child in childRange(of: target) where !nodes[child].flags.contains(.removed) && nodes[child].kind != .group {
            current[names[child]] = NodeID(child)
        }
        let entries = listing.childRange(of: listing.root)
        guard entries.count == current.count else { return false }
        for child in entries {
            guard let id = current[listing.names[child]] else { return false }
            let (old, new) = (nodes[Int(id)], listing.nodes[child])
            guard old.kind == new.kind,
                  old.flags.intersection(Self.listedFlags) == new.flags.intersection(Self.listedFlags) else { return false }
            if new.kind == .directory, !new.flags.contains(.notEntered) {
                // `refresh` keeps what was found below a folder that is still the same one, its errors too.
                guard old.fileID == new.fileID else { return false }
            } else {
                guard old.allocatedSize == new.allocatedSize, old.logicalSize == new.logicalSize,
                      errors[id] == listing.errors[NodeID(child)] else { return false }
            }
        }
        return true
    }

    /// The flags a one-level listing sets for an entry just as a full scan does. The others depend on what else
    /// the scan saw (duplicates, folders reached twice) or come from reading the folder itself (failed, slow).
    private static let listedFlags: Flags = [.notEntered, .protected, .dataless, .sparse, .compressed, .purgeable,
                                             .mayShareBlocks, .firmlink, .hardLinked, .sharesAllBlocks]

    /// Adds a change of size and count to every ancestor of `id`, moving each changed node to its place
    /// among its siblings.
    private func propagate(from id: NodeID, size: Int64, count: Int32) {
        var current = id
        while let parent = parent(of: current) {
            reposition(current, in: parent)
            nodes[Int(parent)].size += size
            nodes[Int(parent)].descendantCount += count
            current = parent
        }
    }

    /// Whether `a` comes before `b` among siblings: larger first, removed last, then by ID.
    private func precedes(_ a: NodeID, _ b: NodeID) -> Bool {
        let (nodeA, nodeB) = (nodes[Int(a)], nodes[Int(b)])
        let (removedA, removedB) = (nodeA.flags.contains(.removed), nodeB.flags.contains(.removed))
        if removedA != removedB { return removedB }
        return nodeA.size != nodeB.size ? nodeA.size > nodeB.size : a < b
    }

    /// Moves one child whose size changed to its place in its parent's otherwise sorted block.
    private func reposition(_ child: NodeID, in parent: NodeID) {
        guard sortedChildren.count == nodes.count else { return }
        let range = childRange(of: parent)
        guard var index = sortedChildren[range].firstIndex(of: child) else { return }
        while index > range.lowerBound, precedes(child, sortedChildren[index - 1]) {
            sortedChildren.swapAt(index, index - 1)
            index -= 1
        }
        while index + 1 < range.upperBound, precedes(sortedChildren[index + 1], child) {
            sortedChildren.swapAt(index, index + 1)
            index += 1
        }
    }

    /// The node at a path below the root, by names; nil if there is none.
    func node(atRelativePath path: String) -> NodeID? {
        var current = root
        for component in path.split(separator: "/") {
            guard let next = children(of: current).first(where: { names[Int($0)] == component }) else { return nil }
            current = next
        }
        return current
    }

    /// The node's path below the root ("" for the root), the inverse of `node(atRelativePath:)`.
    func relativePath(of id: NodeID) -> String {
        lineage(of: id).dropFirst().map { names[Int($0)] }.joined(separator: "/")
    }

    /// Takes a node out of the tree after it was moved to the Trash: its size and count leave every
    /// total above it, and the sibling order above it is brought up to date.
    func remove(_ id: NodeID) {
        guard id != root, !nodes[Int(id)].flags.contains(.removed) else { return }
        nodes[Int(id)].flags.insert(.removed)
        nodes[Int(nodes[Int(id)].parent)].removedChildren += 1
        propagate(from: id, size: -nodes[Int(id)].size, count: -(nodes[Int(id)].descendantCount + 1))
    }

    private func sortChildren(of id: NodeID) {
        guard sortedChildren.count == nodes.count, nodes[Int(id)].childCount > 0 else { return }
        let range = childRange(of: id)
        let ordered = sortedChildren[range].sorted(by: precedes)
        sortedChildren.replaceSubrange(range, with: ordered)
    }

    /// How many nodes the root reaches; the arrays also hold nodes replaced by updates or removed.
    var reachableCount: Int { Int(nodes[Int(root)].descendantCount) + 1 }

    /// Rebuilds the arrays when updates have left more garbage in them than tree. IDs change.
    func compactIfWasteful() {
        guard sortedChildren.count == nodes.count, nodes.count > 2 * reachableCount + 50_000 else { return }
        compact()
    }

    /// Rebuilds the arrays with only what the root reaches, breadth first, each child block in sorted order.
    func compact() {
        precondition(sortedChildren.count == nodes.count, "the tree must be finished")
        var order: [NodeID] = [root]
        order.reserveCapacity(reachableCount)
        var map = [NodeID](repeating: -1, count: nodes.count)
        map[Int(root)] = 0
        var index = 0
        while index < order.count {
            for child in children(of: order[index]) {
                map[Int(child)] = NodeID(order.count)
                order.append(child)
            }
            index += 1
        }
        var rebuilt: [Node] = []
        rebuilt.reserveCapacity(order.count)
        for old in order {
            var node = nodes[Int(old)]
            let live = children(of: old)
            node.parent = old == root ? -1 : map[Int(node.parent)]
            node.firstChild = live.first.map { map[Int($0)] } ?? 0
            node.childCount = Int32(live.count)
            node.removedChildren = 0
            rebuilt.append(node)
        }
        names = order.map { names[Int($0)] }
        basePaths = Dictionary(uniqueKeysWithValues: basePaths.compactMap { id, path in
            map[Int(id)] >= 0 ? (map[Int(id)], path) : nil
        })
        errors = Dictionary(uniqueKeysWithValues: errors.compactMap { id, code in
            map[Int(id)] >= 0 ? (map[Int(id)], code) : nil
        })
        nodes = rebuilt
        sortedChildren = (0 ..< NodeID(nodes.count)).map { $0 }
    }

    /// Sums sizes and counts up the tree and orders each directory's children by size.
    func finish() {
        for index in nodes.indices {
            nodes[index].size = nodes[index].kind == .file && !nodes[index].flags.contains(.duplicate)
                ? nodes[index].allocatedSize : 0
            nodes[index].descendantCount = 0
        }
        for index in stride(from: nodes.count - 1, through: 1, by: -1) {
            let parent = Int(nodes[index].parent)
            nodes[parent].size += nodes[index].size
            nodes[parent].descendantCount += nodes[index].descendantCount + 1
        }
        sortedChildren = (0 ..< NodeID(nodes.count)).map { $0 }
        for index in nodes.indices where nodes[index].childCount > 0 {
            sortChildren(of: NodeID(index))
        }
    }
}
