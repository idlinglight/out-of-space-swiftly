import Darwin
import Foundation

/// A directory tree built for one test in a fresh temporary directory, removed again on deinit (also when
/// it holds unreadable folders or paths longer than `PATH_MAX`).
final class FixtureTree {
    /// The tree's root, symlinks resolved (`/private/var/…`), as the scanner reports paths.
    let root: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        root = base.appendingPathComponent("oos-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    deinit {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY)
        if descriptor >= 0 {
            Self.removeContents(of: descriptor)
            close(descriptor)
        }
        rmdir(root.path)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = url(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file of `size` bytes that do not compress, so its allocated size is its length rounded up.
    @discardableResult
    func file(_ path: String, size: Int) throws -> URL {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        let bytes = (0 ..< size).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
        try Data(bytes).write(to: url)
        return url
    }

    func hardLink(_ path: String, to target: String) throws {
        try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try check(link(url(target).path, url(path).path))
    }

    func clone(_ path: String, of source: String) throws {
        try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try check(clonefile(url(source).path, url(path).path, 0))
    }

    /// A file `length` bytes long with data only in its first and last 4 KiB.
    func sparseFile(_ path: String, length: Int) throws {
        let descriptor = open(url(path).path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        try check(descriptor)
        defer { close(descriptor) }
        let block = [UInt8](repeating: 0x5A, count: 4096)
        try check(Int32(pwrite(descriptor, block, block.count, 0)))
        try check(Int32(pwrite(descriptor, block, block.count, off_t(length - block.count))))
    }

    func symlink(_ path: String, to destination: String) throws {
        try check(Darwin.symlink(destination, url(path).path))
    }

    func setPermissions(_ path: String, _ mode: mode_t) throws {
        try check(chmod(url(path).path, mode))
    }

    /// `depth` nested directories named `name` below `path`, with a file at the bottom; returns the full
    /// path's length. Built with `mkdirat`/`openat`, as such paths are too long for path-based calls.
    func deepTree(below path: String, depth: Int, name: String, fileSize: Int) throws -> Int {
        var descriptor = open(url(path).path, O_RDONLY | O_DIRECTORY)
        try check(descriptor)
        for _ in 0 ..< depth {
            try check(mkdirat(descriptor, name, 0o755))
            let next = openat(descriptor, name, O_RDONLY | O_DIRECTORY)
            close(descriptor)
            try check(next)
            descriptor = next
        }
        defer { close(descriptor) }
        let file = openat(descriptor, "bottom.bin", O_CREAT | O_WRONLY, 0o644)
        try check(file)
        let bytes = [UInt8](repeating: 0x33, count: fileSize)
        _ = write(file, bytes, bytes.count)
        close(file)
        return url(path).path.utf8.count + depth * (name.utf8.count + 1) + "/bottom.bin".utf8.count
    }

    /// Bytes on disk, as `du` counts them.
    func allocatedSize(_ path: String) -> Int64 {
        var info = stat()
        guard lstat(url(path).path, &info) == 0 else { return -1 }
        return Int64(info.st_blocks) * 512
    }

    private func check(_ result: Int32) throws {
        if result < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Deletes everything below the open directory, depth first without recursion (fixture trees can be
    /// deeper than a test thread's stack allows), making unreadable folders readable on the way.
    private static func removeContents(of root: Int32) {
        struct Frame {
            var descriptor: Int32
            var name: String?
            var directories: [String]
        }
        var stack = [Frame(descriptor: dup(root), name: nil, directories: emptyFiles(of: root))]
        while let top = stack.last {
            if let name = stack[stack.count - 1].directories.popLast() {
                fchmodat(top.descriptor, name, 0o755, AT_SYMLINK_NOFOLLOW)
                let child = openat(top.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if child >= 0 {
                    stack.append(Frame(descriptor: child, name: name, directories: emptyFiles(of: child)))
                }
            } else {
                stack.removeLast()
                close(top.descriptor)
                if let name = top.name, let parent = stack.last {
                    unlinkat(parent.descriptor, name, AT_REMOVEDIR)
                }
            }
        }
    }

    /// Unlinks the files in a directory and returns the names of its subdirectories.
    private static func emptyFiles(of descriptor: Int32) -> [String] {
        let listing = dup(descriptor)
        guard let directory = fdopendir(listing) else {
            close(listing)
            return []
        }
        defer { closedir(directory) }
        var directories: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name == "." || name == ".." { continue }
            if Int32(entry.pointee.d_type) == DT_DIR {
                directories.append(name)
            } else {
                unlinkat(descriptor, name, 0)
            }
        }
        return directories
    }
}
