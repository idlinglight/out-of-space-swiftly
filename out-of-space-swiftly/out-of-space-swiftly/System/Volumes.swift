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

/// The mounted volumes as the start view shows them at one moment: those that have answered with their
/// figures, those that have not without.
nonisolated struct VolumeList: Sendable, Equatable {
    /// One mount point.
    struct Entry: Sendable, Equatable, Identifiable {
        var url: URL
        /// The volume's figures; nil while it has not answered.
        var info: VolumeInfo?

        var id: URL { url }
        /// The volume's own name once it has answered; until then the one its mount point carries.
        var name: String { info?.name ?? (isRoot ? "Startup Disk" : url.lastPathComponent) }
        var isRoot: Bool { url.path == "/" }
    }

    /// False while macOS has not said which volumes are mounted.
    var isListed = true
    /// `/` first, the rest by mount point.
    var entries: [Entry] = []

    /// `/` first, then by the name of the mount point (as a rule the volume's name), then by its path. The
    /// order rests on the mount points alone, so an entry keeps its place when its volume answers.
    static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            let byName = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
            return byName == .orderedSame ? a.url.path < b.url.path : byName == .orderedAscending
        }
    }
}

/// The mounted volumes.
nonisolated enum Volumes {
    /// The volumes worth showing a user, as they answer. The list of mount points and each volume are read
    /// on threads of their own (`Blocking`).
    ///
    /// The first list comes when every volume has answered. If the mount points are not there after
    /// `timeout`, a list says so (`isListed` false). If a volume has not answered `timeout` after it was
    /// asked, a list has it as an entry without figures; a new list follows whenever such a volume answers.
    /// The stream ends when all have. A volume that cannot be read is left out.
    ///
    /// A volume that never answers keeps its thread and leaves the stream open; whoever follows the stream
    /// stops by no longer asking.
    static func overview(
        timeout: Duration = .seconds(3),
        mountPoints: @escaping @Sendable () -> [URL] = { browsableVolumeURLs() },
        using load: @escaping @Sendable (URL) throws -> VolumeInfo = { try VolumeInfo.load($0) }
    ) -> AsyncStream<VolumeList> {
        // Every list is complete in itself, so only the newest matters to a reader that is behind.
        let (lists, continuation) = AsyncStream.makeStream(of: VolumeList.self, bufferingPolicy: .bufferingNewest(1))
        let overview = Overview(continuation)
        continuation.onTermination = { [weak overview] _ in overview?.abandon() }
        Blocking.startThread("Volume list") {
            let urls = mountPoints()
            overview.listed(urls)
            for url in urls {
                Blocking.startThread("Volume \(url.path)") { overview.answered(url, with: try? load(url)) }
            }
            // The volumes' time runs from when they were asked, not from when the list was.
            Blocking.after(timeout) { overview.volumesAreLate() }
        }
        Blocking.after(timeout) { overview.listIsLate() }
        return lists
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

    /// What is known of the volumes so far, and the stream it is reported on. Lists are sent with the state
    /// locked, so they arrive in the order of the changes they show.
    private nonisolated final class Overview: Sendable {
        private struct State {
            /// The mount points; nil until macOS has listed them.
            var urls: [URL]?
            /// What each volume answered: its figures, or nil for one that could not be read. No entry
            /// while it has not answered.
            var answers: [URL: VolumeInfo?] = [:]
            var isListLate = false
            var areVolumesLate = false
            var isFinished = false
        }
        private let state = Mutex(State())
        private let continuation: AsyncStream<VolumeList>.Continuation
        /// Nobody follows the stream any more. Not part of `state`: the stream says so while a list is
        /// being sent, with the state locked.
        private let isAbandoned = Atomic(false)

        init(_ continuation: AsyncStream<VolumeList>.Continuation) {
            self.continuation = continuation
        }

        func listed(_ urls: [URL]) {
            change { $0.urls = urls }
        }

        /// One volume's answer; nil for one that could not be read.
        func answered(_ url: URL, with info: VolumeInfo?) {
            change { $0.answers.updateValue(info, forKey: url) }
        }

        func listIsLate() {
            change { $0.isListLate = true }
        }

        func volumesAreLate() {
            change { $0.areVolumesLate = true }
        }

        func abandon() {
            isAbandoned.store(true, ordering: .relaxed)
        }

        /// Applies `change` and reports the list if there is something to show: every volume has answered,
        /// or the wait for what is still missing (the mount points, then the volumes) is over.
        private func change(_ change: (inout State) -> Void) {
            state.withLock { state in
                guard !state.isFinished, !isAbandoned.load(ordering: .relaxed) else { return }
                change(&state)
                guard let urls = state.urls else {
                    if state.isListLate { continuation.yield(VolumeList(isListed: false)) }
                    return
                }
                let isComplete = urls.allSatisfy { state.answers[$0] != nil }
                guard isComplete || state.areVolumesLate else { return }
                let entries = urls.compactMap { url -> VolumeList.Entry? in
                    guard let answer = state.answers[url] else { return VolumeList.Entry(url: url) }
                    return answer.map { VolumeList.Entry(url: url, info: $0) }
                }
                continuation.yield(VolumeList(entries: VolumeList.ordered(entries)))
                if isComplete {
                    state.isFinished = true
                    continuation.finish()
                }
            }
        }

        /// The time is up.
        func close() {
            finish { _ in true }
        }

        /// Hands over what has arrived if `isOver` says so and nothing was handed over before.
        private func finish(if isOver: (inout State) -> Bool) {
            let handover = state.withLock { state -> (CheckedContinuation<[VolumeInfo], Never>, [VolumeInfo])? in
                guard isOver(&state), let continuation = state.continuation else { return nil }
                state.continuation = nil
                defer { state.volumes = [] }
                return (continuation, state.volumes)
            }
            if let (continuation, volumes) = handover { continuation.resume(returning: volumes) }
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
