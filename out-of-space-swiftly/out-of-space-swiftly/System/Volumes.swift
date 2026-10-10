import Darwin
import Foundation

/// One mounted volume: what it is and how full it is. Built from the volume's resource values and
/// `getattrlist(2)`; nothing inside the volume is enumerated. Reading it can block on a slow or network
/// volume, so do it off the main actor.
///
/// All volumes in an APFS container report the container's total and available space. "Total minus
/// available" is therefore how full the container is, while `usedSpace` (`ATTR_VOL_SPACEUSED`) is what this
/// volume itself holds; the two differ whenever volumes share a container (docs/SCANNING.md, section 5).
nonisolated struct VolumeInfo: Sendable, Hashable, Identifiable {
    /// The mount point.
    var url: URL
    /// The name Finder shows.
    var name: String
    /// Bytes. For APFS, the container's size.
    var totalCapacity: Int64
    /// Bytes an ordinary process may still write. For APFS, shared by all volumes in the container.
    var availableCapacity: Int64
    /// Available bytes including what the system would free for an important request (purgeable files,
    /// caches). Some volumes report 0 here.
    var availableCapacityForImportantUsage: Int64?
    /// This volume's own used bytes (`ATTR_VOL_SPACEUSED`).
    var usedSpace: Int64?
    /// Files and directories on the volume (`ATTR_VOL_FILECOUNT`, `ATTR_VOL_DIRCOUNT`): a cheap progress
    /// denominator for a whole-volume scan.
    var fileCount: Int?
    var directoryCount: Int?
    var isRootFileSystem: Bool
    /// Connected to an internal bus; nil when the system doesn't know.
    var isInternal: Bool?
    var isRemovable: Bool
    var isEjectable: Bool
    var isLocal: Bool
    var isBrowsable: Bool
    var isReadOnly: Bool
    /// Such as "APFS" or "APFS (Case-sensitive)".
    var formatDescription: String?
    var uuid: UUID?

    var id: URL { url }

    /// Space the system could free on demand: important-usage capacity minus available, never negative.
    var purgeableEstimate: Int64 {
        max(0, (availableCapacityForImportantUsage ?? availableCapacity) - availableCapacity)
    }

    /// How full the volume's container is: total minus available.
    var containerUsedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    /// The used figure to show next to `totalCapacity`.
    ///
    /// `/` stands for the Mac's disk. Since macOS 10.15 it is the sealed system volume, whose own used space
    /// is only the system's; the user's files are on the hidden Data volume in the same container (and
    /// look-ups of paths there return `/`, see `Volumes.volume(containing:)`). So `/` shows the container
    /// figure, as the system's storage overview does. Other volumes show their own used space, which is what
    /// a scan of them can account for; on a volume that shares its container, used plus available is then
    /// less than total, the rest belonging to its siblings.
    var displayedUsedCapacity: Int64 {
        isRootFileSystem ? containerUsedCapacity : (usedSpace ?? containerUsedCapacity)
    }

    static let resourceKeys: Set<URLResourceKey> = [
        .volumeLocalizedNameKey, .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
        .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey, .volumeUUIDStringKey,
    ]

    /// Reads the volume mounted at `volumeURL`, which must be its root.
    static func load(_ volumeURL: URL) throws -> VolumeInfo {
        let values = try volumeURL.resourceValues(forKeys: resourceKeys)
        let attributes = try? VolumeAttributes.read(volumeRoot: volumeURL)
        return VolumeInfo(
            url: volumeURL,
            name: values.volumeLocalizedName ?? values.volumeName ?? volumeURL.lastPathComponent,
            totalCapacity: values.volumeTotalCapacity.map(Int64.init) ?? attributes?.size ?? 0,
            availableCapacity: values.volumeAvailableCapacity.map(Int64.init) ?? attributes?.availableSpace ?? 0,
            availableCapacityForImportantUsage: values.volumeAvailableCapacityForImportantUsage,
            usedSpace: attributes?.usedSpace,
            fileCount: attributes?.fileCount,
            directoryCount: attributes?.directoryCount,
            isRootFileSystem: values.volumeIsRootFileSystem ?? false,
            isInternal: values.volumeIsInternal,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isLocal: values.volumeIsLocal ?? false,
            isBrowsable: values.volumeIsBrowsable ?? false,
            isReadOnly: values.volumeIsReadOnly ?? false,
            formatDescription: values.volumeLocalizedFormatDescription,
            uuid: values.volumeUUIDString.flatMap(UUID.init(uuidString:))
        )
    }
}

/// The mounted volumes.
nonisolated enum Volumes {
    /// The volumes worth showing a user: browsable, not hidden (which leaves out the system's own volumes
    /// under `/System/Volumes`), `/` first, the rest by name. Volumes that can't be read are left out.
    static func browsable() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(VolumeInfo.resourceKeys), options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { try? VolumeInfo.load($0) }
            .filter(\.isBrowsable)
            .sorted { a, b in
                if a.isRootFileSystem != b.isRootFileSystem { return a.isRootFileSystem }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// The volume that holds `url`, which must exist. Paths on the Data volume (home folders, `/private`)
    /// resolve to `/`, the volume group's root, not to `/System/Volumes/Data`.
    static func volume(containing url: URL) throws -> VolumeInfo {
        guard let volumeURL = try url.resourceValues(forKeys: [.volumeURLKey]).volume else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        return try VolumeInfo.load(volumeURL)
    }
}

/// The figures `getattrlist(2)` has for a volume and Foundation doesn't: own used space and object counts.
/// Size and available space come along as a fallback and a check on the parsing.
nonisolated struct VolumeAttributes: Sendable, Equatable {
    var size: Int64?
    var availableSpace: Int64?
    var usedSpace: Int64?
    var fileCount: Int?
    var directoryCount: Int?

    private static let requested: attrgroup_t = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SIZE)
        | attrgroup_t(ATTR_VOL_SPACEAVAIL) | attrgroup_t(ATTR_VOL_SPACEUSED) | attrgroup_t(ATTR_VOL_FILECOUNT)
        | attrgroup_t(ATTR_VOL_DIRCOUNT)

    /// getattrlist(2) says volume attributes need the volume's root. macOS 26 also answers for a path inside
    /// one, with the figures of the volume `statfs` names for it (the Data volume for paths under `/Users`).
    static func read(volumeRoot: URL) throws -> VolumeAttributes {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.volattr = requested
        // u_int32_t length, attribute_set_t, then 3 × off_t and 2 × u_int32_t.
        let expectedLength = 4 + MemoryLayout<attribute_set_t>.size + 3 * 8 + 2 * 4
        return try withUnsafeTemporaryAllocation(byteCount: 128, alignment: 8) { buffer in
            // FSOPT_PACK_INVAL_ATTRS packs every requested attribute, so the offsets are fixed and the returned
            // set only says which values are valid. (Even without it, an autofs mount packed counts it did not
            // mark as returned: skipping by the returned set would misread what follows.)
            let options = UInt32(FSOPT_PACK_INVAL_ATTRS | FSOPT_NOFOLLOW)
            let error = volumeRoot.withUnsafeFileSystemRepresentation { path in
                getattrlist(path, &list, buffer.baseAddress, buffer.count, options) == 0 ? 0 : errno
            }
            guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
            let length = Int(buffer.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            guard length >= expectedLength else { throw POSIXError(.EBADMSG) }
            let returned = buffer.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self).volattr

            // Volume attributes follow the man page's description order, not bit order: SPACEUSED (0x800000)
            // comes right after SPACEAVAIL, before FILECOUNT (0x200) and DIRCOUNT (0x400). Verified against
            // statfs on APFS volumes.
            var offset = 4 + MemoryLayout<attribute_set_t>.size
            func next<T: FixedWidthInteger>(_ type: T.Type, _ attribute: Int32) -> Int64? {
                defer { offset += MemoryLayout<T>.size }
                guard returned & attrgroup_t(attribute) != 0 else { return nil }
                return Int64(buffer.loadUnaligned(fromByteOffset: offset, as: T.self))
            }
            let size = next(off_t.self, ATTR_VOL_SIZE)
            let availableSpace = next(off_t.self, ATTR_VOL_SPACEAVAIL)
            let usedSpace = next(off_t.self, ATTR_VOL_SPACEUSED)
            let fileCount = next(UInt32.self, ATTR_VOL_FILECOUNT)
            let directoryCount = next(UInt32.self, ATTR_VOL_DIRCOUNT)
            return VolumeAttributes(
                size: size, availableSpace: availableSpace, usedSpace: usedSpace,
                fileCount: fileCount.map(Int.init), directoryCount: directoryCount.map(Int.init)
            )
        }
    }
}
