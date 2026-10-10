import Darwin

/// One directory entry as `getattrlistbulk(2)` reports it.
nonisolated struct DirectoryEntry: Sendable, Equatable {
    var name = ""
    /// `fsobj_type_t`: `VREG`, `VDIR`, `VLNK`, …
    var objectType: UInt32 = 0
    /// `st_flags`: `SF_DATALESS`, `SF_FIRMLINK`, `UF_COMPRESSED`, …
    var flags: UInt32 = 0
    var device: Int32 = 0
    var fileID: UInt64 = 0
    /// `DIR_MNTSTATUS_*`, directories only.
    var mountStatus: UInt32 = 0
    var linkCount: UInt32 = 0
    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0
    var privateSize: Int64 = 0
    var cloneID: UInt64 = 0
    var cloneReferences: UInt32 = 0
    /// `EF_*` flags.
    var extendedFlags: UInt64 = 0
    /// errno for this entry (`ATTR_CMN_ERROR`), 0 if none.
    var error: UInt32 = 0

    var isDirectory: Bool { objectType == VDIR.rawValue }
    var isFile: Bool { objectType == VREG.rawValue }
    var isSymlink: Bool { objectType == VLNK.rawValue }
}

/// Reads whole directories with `getattrlistbulk(2)`, many entries and all their sizes per system call.
///
/// Not thread-safe: each scanning thread owns one reader and its buffer.
nonisolated final class DirectoryReader {
    private let buffer: UnsafeMutableRawBufferPointer
    private var attributes = attrlist()

    init(bufferSize: Int = 256 * 1024) {
        buffer = .allocate(byteCount: bufferSize, alignment: 8)
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = Self.bits(ATTR_CMN_RETURNED_ATTRS, ATTR_CMN_NAME, ATTR_CMN_ERROR, ATTR_CMN_DEVID,
                                          ATTR_CMN_OBJTYPE, ATTR_CMN_FLAGS, ATTR_CMN_FILEID)
        attributes.dirattr = Self.bits(ATTR_DIR_MOUNTSTATUS)
        attributes.fileattr = Self.bits(ATTR_FILE_LINKCOUNT, ATTR_FILE_TOTALSIZE, ATTR_FILE_ALLOCSIZE)
        // With FSOPT_ATTR_CMN_EXTENDED the fork group carries the ATTR_CMNEXT_* attributes.
        attributes.forkattr = Self.bits(ATTR_CMNEXT_PRIVATESIZE, ATTR_CMNEXT_CLONEID, ATTR_CMNEXT_EXT_FLAGS,
                                        ATTR_CMNEXT_CLONE_REFCNT)
    }

    deinit {
        buffer.deallocate()
    }

    /// Reads every entry of the open directory `descriptor`, calling `body` for each. Returns 0, or the errno
    /// that stopped the listing early (entries before it were delivered).
    func read(_ descriptor: Int32, _ body: (DirectoryEntry) -> Void) -> Int32 {
        // getattrlistbulk never follows symlinks; FSOPT_NOFOLLOW is not one of its options.
        let options = UInt64(FSOPT_ATTR_CMN_EXTENDED)
        while true {
            let count = withUnsafeMutablePointer(to: &attributes) { list in
                getattrlistbulk(descriptor, list, buffer.baseAddress, buffer.count, options)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                return code
            }
            if count == 0 { return 0 }
            var entry = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0 ..< count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                body(Self.parse(entry))
                entry += length
            }
        }
    }

    /// Unpacks one entry. Attributes appear in the man page's description order (not bit order), each
    /// 4-byte aligned, and only those named in the returned set; `ATTR_CMN_ERROR` comes right after it.
    static func parse(_ start: UnsafeRawPointer) -> DirectoryEntry {
        var cursor = Cursor(base: start, offset: 4)
        let common = cursor.u32()
        _ = cursor.u32() // volume attributes
        let directory = cursor.u32()
        let file = cursor.u32()
        let extended = cursor.u32()

        var entry = DirectoryEntry()
        if common & bits(ATTR_CMN_ERROR) != 0 { entry.error = cursor.u32() }
        if common & bits(ATTR_CMN_NAME) != 0 {
            let reference = cursor.offset
            let offset = Int(cursor.i32())
            _ = cursor.u32() // length, including the terminating NUL
            entry.name = String(cString: (start + reference + offset).assumingMemoryBound(to: CChar.self))
        }
        if common & bits(ATTR_CMN_DEVID) != 0 { entry.device = cursor.i32() }
        if common & bits(ATTR_CMN_OBJTYPE) != 0 { entry.objectType = cursor.u32() }
        if common & bits(ATTR_CMN_FLAGS) != 0 { entry.flags = cursor.u32() }
        if common & bits(ATTR_CMN_FILEID) != 0 { entry.fileID = cursor.u64() }

        if directory & bits(ATTR_DIR_MOUNTSTATUS) != 0 { entry.mountStatus = cursor.u32() }

        if file & bits(ATTR_FILE_LINKCOUNT) != 0 { entry.linkCount = cursor.u32() }
        if file & bits(ATTR_FILE_TOTALSIZE) != 0 { entry.logicalSize = cursor.i64() }
        if file & bits(ATTR_FILE_ALLOCSIZE) != 0 { entry.allocatedSize = cursor.i64() }

        if extended & bits(ATTR_CMNEXT_PRIVATESIZE) != 0 { entry.privateSize = cursor.i64() }
        if extended & bits(ATTR_CMNEXT_CLONEID) != 0 { entry.cloneID = cursor.u64() }
        if extended & bits(ATTR_CMNEXT_EXT_FLAGS) != 0 { entry.extendedFlags = cursor.u64() }
        if extended & bits(ATTR_CMNEXT_CLONE_REFCNT) != 0 { entry.cloneReferences = cursor.u32() }
        return entry
    }

    /// The C macros import as `Int32` or `UInt32`, depending on their value.
    private static func bits(_ values: any BinaryInteger...) -> UInt32 {
        values.reduce(0) { $0 | UInt32(truncatingIfNeeded: $1) }
    }

    private struct Cursor {
        let base: UnsafeRawPointer
        var offset: Int

        mutating func u32() -> UInt32 { defer { offset += 4 }; return base.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        mutating func i32() -> Int32 { defer { offset += 4 }; return base.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
        mutating func u64() -> UInt64 { defer { offset += 8 }; return base.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
        mutating func i64() -> Int64 { defer { offset += 8 }; return base.loadUnaligned(fromByteOffset: offset, as: Int64.self) }
    }
}
