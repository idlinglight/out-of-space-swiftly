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
        /// Reading the directory failed or stopped early; see `error(of:)`.
        static let failed = Flags(rawValue: 1 << 10)
        /// Reading the directory took longer than the scan's patience.
        static let slow = Flags(rawValue: 1 << 11)
        /// A file with more than one link.
        static let hardLinked = Flags(rawValue: 1 << 12)
        /// A member of a full-clone set: shares all its blocks with other files.
        static let sharesAllBlocks = Flags(rawValue: 1 << 13)
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
    /// Children of each directory ordered by size, largest first; filled by `finish()`.
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

    /// Whether the node can contain others (a directory that was entered, or a group).
    func isContainer(_ id: NodeID) -> Bool {
        let node = nodes[Int(id)]
        return (node.kind == .directory || node.kind == .group) && node.childCount > 0
    }

    /// The node's children, largest first once the tree is finished; in reading order before.
    func children(of id: NodeID) -> ArraySlice<NodeID> {
        let node = nodes[Int(id)]
        let range = Int(node.firstChild) ..< Int(node.firstChild) + Int(node.childCount)
        if sortedChildren.count == nodes.count { return sortedChildren[range] }
        return ArraySlice(range.map { NodeID($0) })
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
        var sorted = [NodeID](repeating: 0, count: nodes.count)
        for index in nodes.indices where nodes[index].childCount > 0 {
            let first = Int(nodes[index].firstChild)
            let range = first ..< first + Int(nodes[index].childCount)
            let ordered = range.sorted { nodes[$0].size != nodes[$1].size ? nodes[$0].size > nodes[$1].size : $0 < $1 }
            for (offset, child) in ordered.enumerated() { sorted[first + offset] = NodeID(child) }
        }
        sortedChildren = sorted
    }
}
