import Darwin
import Foundation
import Synchronization

/// One mounted volume: what it is and how full it is. Built from the volume's resource values and
/// `getattrlist(2)`; nothing inside the volume is enumerated. Reading it can block on a slow or network
/// volume, so do it off the main actor.
///
/// All volumes in an APFS container report the container's total and available space. "Total minus
/// available" is therefore how full the container is, while `ATTR_VOL_SPACEUSED` is what one volume itself
/// holds; the two differ whenever volumes share a container (docs/SCANNING.md, section 5).
///
/// `/` stands for the Mac's disk. Since macOS 10.15 it is the sealed system volume, whose own figures are
/// only the system's; the user's files are on the Data volume in the same container, which is hidden and
/// which look-ups of paths there resolve to `/` (see `Volumes.volume(containing:)`). A scan of `/` walks
/// both (ADR-0004), so for `/` the used space and counts are the sums of the two volumes'.
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
    /// This volume's own `getattrlist` figures. Empty for network volumes, which aren't asked: the scanner
    /// doesn't enter them, so their counts are no use, and every call is one more chance to hang.
    var attributes: VolumeAttributes
    /// For `/`, the Data volume's figures (`/System/Volumes/Data`); nil for other volumes.
    var dataVolumeAttributes: VolumeAttributes?
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

    /// Used bytes that a scan of `url` can account for (`ATTR_VOL_SPACEUSED`): the volume's own, plus the
    /// Data volume's for `/`.
    var usedSpace: Int64? { combined(\.usedSpace) }
    /// Files and directories that a scan of `url` walks (`ATTR_VOL_FILECOUNT`, `ATTR_VOL_DIRCOUNT`, with the
    /// Data volume's for `/`): a cheap progress denominator.
    var fileCount: Int? { combined(\.fileCount) }
    var directoryCount: Int? { combined(\.directoryCount) }

    /// Space the system could free on demand: important-usage capacity minus available, never negative.
    var purgeableEstimate: Int64 {
        max(0, (availableCapacityForImportantUsage ?? availableCapacity) - availableCapacity)
    }

    /// How full the volume's container is: total minus available.
    var containerUsedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    /// The used figure to show next to `totalCapacity`: `usedSpace`, so that it matches what a scan finds,
    /// or the container figure when the volume doesn't report its own.
    var displayedUsedCapacity: Int64 { usedSpace ?? containerUsedCapacity }

    /// What the container holds beyond `displayedUsedCapacity`: its other volumes (for `/`: Preboot, VM,
    /// Update, Recovery) and file system overhead. Total = displayed used + this + available.
    var otherContainerUsage: Int64 { max(0, containerUsedCapacity - displayedUsedCapacity) }

    private func combined<T: AdditiveArithmetic>(_ figure: KeyPath<VolumeAttributes, T?>) -> T? {
        guard var total = attributes[keyPath: figure] else { return nil }
        if let dataVolumeAttributes {
            guard let data = dataVolumeAttributes[keyPath: figure] else { return nil }
            total += data
        }
        return total
    }

    static let resourceKeys: Set<URLResourceKey> = [
        .volumeLocalizedNameKey, .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
        .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey, .volumeUUIDStringKey,
    ]

    static let dataVolumePath = "/System/Volumes/Data"

    /// Reads the volume mounted at `volumeURL`, which must be its root.
    static func load(_ volumeURL: URL) throws -> VolumeInfo {
        let values = try volumeURL.resourceValues(forKeys: resourceKeys)
        let isLocal = values.volumeIsLocal ?? false
        let isRoot = values.volumeIsRootFileSystem ?? false
        let attributes = isLocal ? (try? VolumeAttributes.read(volumeRoot: volumeURL)) : nil
        let dataVolumeAttributes = isRoot && isMountPoint(dataVolumePath)
            ? try? VolumeAttributes.read(volumeRoot: URL(filePath: dataVolumePath, directoryHint: .isDirectory))
            : nil
        return VolumeInfo(
            url: volumeURL,
            name: values.volumeLocalizedName ?? values.volumeName ?? volumeURL.lastPathComponent,
            totalCapacity: values.volumeTotalCapacity.map(Int64.init) ?? attributes?.size ?? 0,
            availableCapacity: values.volumeAvailableCapacity.map(Int64.init) ?? attributes?.availableSpace ?? 0,
            availableCapacityForImportantUsage: values.volumeAvailableCapacityForImportantUsage,
            attributes: attributes ?? VolumeAttributes(),
            dataVolumeAttributes: dataVolumeAttributes,
            isRootFileSystem: isRoot,
            isInternal: values.volumeIsInternal,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isLocal: isLocal,
            isBrowsable: values.volumeIsBrowsable ?? false,
            isReadOnly: values.volumeIsReadOnly ?? false,
            formatDescription: values.volumeLocalizedFormatDescription,
            uuid: values.volumeUUIDString.flatMap(UUID.init(uuidString:))
        )
    }

    private static func isMountPoint(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == path
    }
}

/// The mounted volumes.
nonisolated enum Volumes {
    /// The volumes worth showing a user, `/` first, the rest by name. Each is read on its own GCD thread (the
    /// calls block, so they stay off Swift's cooperative pool). One that takes longer than `timeout`, such as
    /// a hung network mount, is left out and doesn't hold up the others; its thread finishes on its own.
    static func browsable(timeout: Duration = .seconds(3)) async -> [VolumeInfo] {
        ordered(await load(browsableVolumeURLs(), timeout: timeout) { try VolumeInfo.load($0) })
    }

    /// Mount points of the browsable volumes that aren't hidden (which leaves out the system's own volumes
    /// under `/System/Volumes`). Decided from values fetched with the mount list; no volume is read.
    static func browsableVolumeURLs() -> [URL] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey], options: [.skipHiddenVolumes]
        ) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.volumeIsBrowsableKey]))?.volumeIsBrowsable == true }
    }

    /// The volume that holds `url`, which must exist. Paths on the Data volume (home folders, `/private`)
    /// resolve to `/`, the volume group's root, not to `/System/Volumes/Data`.
    static func volume(containing url: URL) throws -> VolumeInfo {
        guard let volumeURL = try url.resourceValues(forKeys: [.volumeURLKey]).volume else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        return try VolumeInfo.load(volumeURL)
    }

    /// `/` first, then by name.
    static func ordered(_ volumes: [VolumeInfo]) -> [VolumeInfo] {
        volumes.sorted { a, b in
            if a.isRootFileSystem != b.isRootFileSystem { return a.isRootFileSystem }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Runs `load` for every URL at once, each on a GCD thread; failures and late answers are left out.
    static func load(
        _ urls: [URL], timeout: Duration, using load: @escaping @Sendable (URL) throws -> VolumeInfo
    ) async -> [VolumeInfo] {
        await withTaskGroup(of: VolumeInfo?.self) { group in
            for url in urls {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        let once = Once()
                        DispatchQueue.global(qos: .utility).async {
                            let info = try? load(url)
                            if once.claim() { continuation.resume(returning: info) }
                        }
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout / .seconds(1)) {
                            if once.claim() { continuation.resume(returning: nil) }
                        }
                    }
                }
            }
            return await group.reduce(into: []) { volumes, info in
                if let info { volumes.append(info) }
            }
        }
    }

    private nonisolated final class Once: Sendable {
        private let claimed = Mutex(false)
        /// True for the first caller only.
        func claim() -> Bool {
            claimed.withLock { claimed in
                defer { claimed = true }
                return !claimed
            }
        }
    }
}

/// The figures `getattrlist(2)` has for a volume and Foundation doesn't: own used space and object counts.
/// Size and available space come along as a fallback and a check on the parsing.
nonisolated struct VolumeAttributes: Sendable, Hashable {
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
