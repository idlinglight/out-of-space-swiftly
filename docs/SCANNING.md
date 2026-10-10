# Scanning a Mac's file system: notes

What a disk usage scanner on macOS has to know: which APIs are fast, which size to count, what not to
cross, and where the system's privacy protections can stall it. Collected on 2026-10-10 on an Apple
silicon Mac (4 performance cores) with macOS 26.7 and the macOS 27 SDK. The decisions built on these notes
are in [ADR-0004](adr/0004-scanning.md).

Labels: **verified** means tested on that machine or quoted from an SDK header, man page or Apple
document; **likely** means a strong secondary source or consistent with verified facts but untested;
**unsure** is the rest. Nothing was tested inside protected locations (containers, Desktop, Documents,
cloud storage); every privacy claim below comes from documents and reports.

## 1. Enumeration

**FileManager is `getattrlistbulk` underneath** (verified, TN3150 shows the stack:
`_URLEnumeratorGetNextURL` → `getattrlistbulk`). Its extra cost is URL objects and resource-value caches.

Benchmark, warm cache, 100,003 entries in 1,110 directories, best of three, `-O` (verified):

| Method | Time |
|---|---|
| `FileManager.enumerator`, 5 resource keys | 0.353 s |
| `contentsOfDirectory`, recursive | 0.338 s |
| `readdir` + `fstatat` | 0.137 s |
| `fts` | 0.091 s |
| `getattrlistbulk`, 1 thread | 0.079 s |
| `getattrlistbulk`, 2 threads | 0.045 s |
| `getattrlistbulk`, 4 threads | **0.027 s** |
| `getattrlistbulk`, 8 threads | 0.035 s |
| `getattrlistbulk`, 10 threads | 0.050 s |

- Parallel walking helps up to the number of performance cores (`hw.perflevel0.physicalcpu`), then gets
  worse. Cold-cache scaling is not measured.
- `getattrlistbulk(2)` (verified): many entries per call; per-entry errors via `ATTR_CMN_ERROR`; flags
  mount points (`ATTR_DIR_MOUNTSTATUS` & `DIR_MNTSTATUS_MNTPOINT`) and automount triggers
  (`DIR_MNTSTATUS_TRIGGER`); firmlinks carry `SF_FIRMLINK` in `ATTR_CMN_FLAGS`; never follows symlinks;
  no particular order.
- Parsing (verified): attributes are packed in the man page's description order, not bit order. With
  `FSOPT_PACK_INVAL_ATTRS`, directory attributes are still only packed for directories and file attributes
  only for files, so parse by the returned attribute set. `FSOPT_ATTR_CMN_EXTENDED` switches the fork
  attributes to the `ATTR_CMNEXT_*` set.
- **Path length** (verified): `FileManager.enumerator` and `fts` both stop at `PATH_MAX` (1024 bytes) with
  `ENAMETOOLONG` and silently miss deeper files. A walker that opens each directory with `openat` relative
  to its parent's descriptor has no such limit (150 levels tested).
- **File descriptors**: the launchd soft limit is 256 (verified via `launchctl limit maxfiles`); that GUI
  apps start with it is likely. A parallel `openat` walker must raise it or bound open directories.
- Some calls can block for a long time (privacy checks, cloud downloads, network and automount lookups).
  Don't run them on Swift's cooperative thread pool; use dedicated threads and stream results (likely,
  WWDC21 "Swift concurrency: Behind the scenes").

Errors (verified on a directory with mode 000): `open`/`getattrlistbulk` give `EACCES` (13);
FileManager wraps it as Cocoa 257 with the POSIX error underneath and continues if the error handler says
so; `fts` returns `FTS_DNR`. Privacy (TCC) and sandbox denials give `EPERM` (1) (likely), which Cocoa
also maps to 257, so look at the POSIX code. A blocked cloud download gives `EDEADLK`; `ETIMEDOUT` is
possible while one is in progress (TN3150).

## 2. Sizes

Measured on test files (verified):

| File | Logical | Allocated | `PRIVATESIZE` | Extended flags | Clone ID / refs |
|---|---|---|---|---|---|
| 8 MiB original, 2 hard links, cloned twice | 8,388,608 | 8,388,608 | 0 | may share, shares all | same / 3 |
| each of its two clones (`cp -c`) | 8,388,608 | 8,388,608 | 0 | may share, shares all | same / 3 |
| clone with 2 MiB overwritten | 8,388,608 | 8,388,608 | 2,097,152 | may share | own / 1 |
| full copy | 8,388,608 | 8,388,608 | 8,388,608 | – | own / 1 |
| 1 GiB sparse file | 1,073,741,824 | 16,384 | 16,384 | sparse | own / 1 |
| 4 MB text, decmpfs-compressed | 4,000,000 | 36,864 | **0** | – | own / 0 |
| 4-byte file | 4 | 4,096 | 4,096 | – | |
| symlink | 8 | 0 | 0 | – | |

- **Allocated size is what fills a disk**: `ATTR_FILE_ALLOCSIZE`, `totalFileAllocatedSizeKey`, equal to
  `st_blocks × 512` and what `du` shows. Logical size (`ATTR_FILE_TOTALSIZE`, `fileSizeKey`) is wildly off
  for sparse and compressed files.
- **Clones** report their full allocated size each; summing overcounts. A full-clone set
  (`EF_SHARES_ALL_BLOCKS`) can be counted once per `ATTR_CMNEXT_CLONEID`. Partial clones
  (`EF_MAY_SHARE_BLOCKS` only) cannot be deduplicated exactly; `ATTR_CMNEXT_PRIVATESIZE` is the minimum
  unique amount.
- **`PRIVATESIZE` is not "the size"**: it is 0 for every member of a full-clone set *and* for compressed
  files.
- **Hard links** share the file ID (inode); count files with a link count above 1 once per
  `(device, inode)`. `fileResourceIdentifierKey` is the same for both names.
- `(st_dev, inode)` stays unique across an APFS volume group: system-volume inodes have high bits set
  (observed; mechanism likely).
- Foundation has keys for sparse, purgeable, may-share and the clone ID (`fileContentIdentifierKey`), but
  none for shares-all-blocks, private size, clone reference count, link ID, `SF_DATALESS` or
  `SF_FIRMLINK` (verified by grep of `NSURL.h`).
- **Dataless files** (`SF_DATALESS`): reading the flag doesn't download anything, but `stat` and
  `getattrlist` materialize dataless *parent folders*, and `getattrlistbulk` on a dataless directory
  materializes it (TN3150).
- **Local snapshots** (Time Machine keeps hourly ones) hold space no file walk can see. There is no public
  API for their size (likely).

One pass of `getattrlistbulk` gets everything needed (verified): common `RETURNED_ATTRS`, `NAME`, `ERROR`,
`DEVID`, `OBJTYPE`, `FLAGS`, `FILEID`; directory `MOUNTSTATUS`; file `LINKCOUNT`, `TOTALSIZE`,
`ALLOCSIZE`; extended `EXT_FLAGS`, `CLONEID`, `PRIVATESIZE`, `CLONE_REFCNT`.

## 3. What not to cross

- **Mount points**: `/dev`, every volume under `/System/Volumes`, `/Volumes/*`, and less obvious ones such
  as simulator runtime images under `/Library/Developer/CoreSimulator/Volumes` (verified). FileManager
  lists mount points but doesn't descend into them, except the root it was given.
- **`/` and `/System/Volumes/Data` look like the same volume** (verified): same `st_dev`, same
  `volumeIdentifierKey`, and `/Users` has the same `(device, inode)` under both paths. Only `statfs`'s fsid
  and the real device ID (`FSOPT_RETURN_REALDEV`, `ATTR_CMNEXT_REALDEVID`) differ.
- **Firmlinks** join the read-only system volume to the Data volume (`/usr/share/firmlinks`: `/Users`,
  `/Applications`, `/Library`, `/private`, `/Volumes`, `/opt`, `/usr/local` and more). In a
  `getattrlistbulk` listing of `/` they carry `SF_FIRMLINK`; `stat` follows them and doesn't show it
  (verified).
  - Following firmlinks and skipping `/System/Volumes` misses Data-only folders (`.Spotlight-V100`,
    `.fseventsd`, `.DocumentRevisions-V100`, `MobileSoftwareUpdate`, `home`).
  - Walking both counts everything twice. The complete way: walk the system volume with firmlinks as
    leaves, walk `/System/Volumes/Data` separately, and show its folders under their firmlink names.
  - Either way, keep a visited set of directory `(device, inode)` pairs as a backstop.
- **Symlinks**: never follow; count the link itself.
- **Automount**: `/home` is a synthetic symlink to an autofs mount (verified); `/net` may be one. Detect
  triggers with `DIR_MNTSTATUS_TRIGGER` / `isMountTriggerKey` and skip non-local volumes
  (`volumeIsLocalKey`). `setiopolicy_np(IOPOL_TYPE_VFS_TRIGGER_RESOLVE, IOPOL_SCOPE_PROCESS, OFF)` can be
  set without privileges (verified); whether it stops automounts is untested.
- **Cloud files** (`~/Library/Mobile Documents`, `~/Library/CloudStorage/*`): File Provider items start
  dataless and "the system automatically downloads files on POSIX accesses" (FileProvider header).
  `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, …, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)`
  stops that; operations that would download then fail with `EDEADLK` (verified that it can be set
  unprivileged, process or thread scope). The man page says OFF is the default, yet a process started from
  a shell inherited ON (verified): set it explicitly. Foundation has no equivalent.
- **Packages** (apps, Photos libraries): descend for sizing, collapse in the UI. `isPackageKey` asks Launch
  Services; check it only for directories with a name extension.
- **Root-only folders** (`.Spotlight-V100`, `.fseventsd`, `.DocumentRevisions-V100`) give `EACCES` even with
  Full Disk Access (verified).

## 4. Privacy protections (TCC)

- Access is charged to the *responsible* app: for a tool started from Terminal that is Terminal; a grant
  made to another app doesn't apply (likely, Eclectic Light).
- **Other apps' containers** (`~/Library/Containers/*`, macOS 14+): access prompts, also for apps without
  the sandbox; a grant lasts until the app exits; a denial blocks reading (verified, Apple: "Accessing
  files from the macOS App Sandbox"). On the forums, `open()` in Containers and Group Containers is
  reported to stall, sometimes indefinitely, and Apple's advice was to skip those folders (forum 740204).
  A disk scanner vendor reported the checks being slow even after access was granted, acknowledged by
  Apple as a bug, and worked around it by excluding them (DaisyDisk 4.26.1 notes).
- **Group containers** (`~/Library/Group Containers/*`, macOS 15+): prompt unless entitled; consent lasts
  for that app instance (forum 721701).
- **Desktop, Documents, Downloads, cloud storage, removable and network volumes**: a prompt once per app,
  remembered; `EPERM` after a denial. Whether the call blocks while the prompt is up is undocumented
  (likely yes).
- **Mail, Messages, Safari, Photos data**: `EPERM` without a prompt; Full Disk Access only (likely).
- **No public API tells whether a path is protected without triggering the check.** `access(2)` and
  `isReadableKey` look at POSIX permissions only. A deny list built from the real home folder is the
  practical answer. Listing the *names* in `~/Library/Containers` is probably safe; opening the folders
  inside is what triggers (likely).
- **Full Disk Access** covers the folder prompts and the FDA-only data (likely); whether it removes the
  container stalls is unsure. Apple announced on 2026-10-02 that granting it will soon need "very explicit
  user action". An app should work well without it.

## 5. Matching the volume's numbers

- All volumes in an APFS container report the same total and free space (verified).
- Per-volume used space comes from `getattrlist(ATTR_VOL_SPACEUSED)` and matches `diskutil`'s "Capacity
  Consumed" (verified). It need not equal size minus free when volumes share a container (man page).
- Volume attributes are packed in description order too: `ATTR_VOL_SPACEUSED` (bit 0x800000) comes right
  after `ATTR_VOL_SPACEAVAIL`, before `ATTR_VOL_FILECOUNT` and `ATTR_VOL_DIRCOUNT` (verified against
  `statfs`). An autofs mount packed counts it did not mark as returned, even without
  `FSOPT_PACK_INVAL_ATTRS`; with that option every requested attribute is packed (verified).
- The man page says volume attributes need the volume's root; macOS 26.7 answers for any path, with the
  figures of the volume `statfs` names for it (verified).
- `/` is the sealed system volume: its own used space and counts are the system's only. A scan of `/` also
  walks the Data volume (ADR-0004), so the figures to compare with are the sums of both volumes'
  (`/System/Volumes/Data` is a mount point, verified). Total minus available exceeds that sum by the
  container's other volumes: Preboot, VM and Update made up most of a 9 GB difference (verified), the
  unmounted Recovery volume and metadata likely the rest. `volumeURLKey` gives `/` for paths on the Data
  volume, where `statfs` gives `/System/Volumes/Data` (verified).
- `volumeAvailableCapacityForImportantUsageKey` can be 0 (seen on an external APFS volume) (verified).
- Purgeable space ≈ `volumeAvailableCapacityForImportantUsageKey` − `volumeAvailableCapacityKey` (the
  header defines "important" as including space from purging caches) (verified values, likely meaning).
- `ATTR_VOL_FILECOUNT` + `ATTR_VOL_DIRCOUNT` give a cheap progress denominator for a whole-volume scan
  (verified).
- The difference between a scan's total and the volume's used space: places not scanned or not readable,
  snapshots, file system metadata, and clone and compression effects.

## 6. Settings for a scanning process

All settable without privileges (verified): `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` OFF,
`IOPOL_TYPE_VFS_TRIGGER_RESOLVE` OFF (process scope only), `IOPOL_TYPE_VFS_ATIME_UPDATES` OFF, disk I/O
policy `IOPOL_UTILITY` on scan threads.

## 7. Questions only the real app can answer

1. Which dataless-materialization policy a GUI app inherits from launchd.
2. Whether trigger-resolve OFF really stops automounts.
3. What happens on first touch of `~/Library/Containers` and Group Containers: a prompt or not, how long
   `open` blocks, which error after a denial, whether Full Disk Access removes the delay.
4. Whether an app run from Xcode is its own responsible process.
5. Cold-cache thread scaling on a full Data volume.
6. The file descriptor limit a launched app gets.
7. What `getattrlistbulk` reports for dataless files with materialization off.
8. How close "scanned + not scanned + snapshots" lands to the volume's used space.

## Sources

- SDK headers (MacOSX27.0.sdk): `sys/attr.h`, `sys/stat.h`, `sys/resource.h`, `sys/syslimits.h`,
  `launch.h`, Foundation `NSURL.h` and `NSFileManager.h`, FileProvider `NSFileProviderReplicatedExtension.h`
  and `NSFileProviderItem.h`.
- Man pages: getattrlist(2), getattrlistbulk(2), setiopolicy_np(3), open(2), fts(3).
- [TN3150: Getting ready for dataless files](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Updates to Full Disk Access in macOS](https://developer.apple.com/news/?id=p6zjojqw) (2026-10-02)
- Apple Developer Forums threads [740204](https://developer.apple.com/forums/thread/740204),
  [742147](https://developer.apple.com/forums/thread/742147),
  [721701](https://developer.apple.com/forums/thread/721701)
- [DaisyDisk 4.26.1 release notes](https://daisydiskapp.com/blog/daisydisk-4-26-1-released/)
- Eclectic Light: [Privacy: protected folders](https://eclecticlight.co/2026/04/07/privacy-protected-folders/),
  [What are all those Containers?](https://eclecticlight.co/2024/08/05/what-are-all-those-containers/)
