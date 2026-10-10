# ADR-0004: Scanning with our own getattrlistbulk walker

Status: accepted, 2026-10-10

## Context

The facts behind this decision are in [docs/SCANNING.md](../SCANNING.md). In short:

- `FileManager` is a convenience layer over `getattrlistbulk(2)`, about 4.5× slower on a warm cache, stops
  at `PATH_MAX`, and has no keys for the flags a disk scanner needs (shares-all-blocks clones, dataless,
  firmlink).
- Allocated size is what fills the disk. Clones and hard links make a naive sum count blocks twice.
- `/` and `/System/Volumes/Data` share a device number; walking both double counts.
- Cloud files download on access unless the process says otherwise.
- Other apps' containers are protected; first access prompts, and file system calls there have been seen
  to stall, even with access granted.
- Some calls can block for a long time, and no public API predicts which.

## Decision

**Walker**

- Our own walker over `getattrlistbulk`, opening each directory with `openat` relative to its parent's
  descriptor (no path length limit). One call per directory batch fetches name, type, flags, IDs, mount
  status, link count, logical and allocated size, extended flags, clone ID and private size.
- Directories are work items for a small pool of dedicated threads (default: the number of performance
  cores), not Swift's cooperative pool. Results reach the window's model in batches through an async
  stream; the tree is built off the main actor.
- At launch the process sets: dataless materialization off, automount trigger resolution off, access time
  updates off; scan threads use the utility I/O policy. The file descriptor soft limit is raised to fit
  the pool. The effective values are logged.

**What counts**

- The size shown is the allocated size. Files with more than one link count once per `(device, inode)`.
  Members of a full-clone set (`EF_SHARES_ALL_BLOCKS`) count once per clone ID. Partial clones count in
  full and are marked as possibly sharing blocks. Logical size and the sparse, compressed, dataless and
  purgeable flags are kept for the inspector.

**What not to cross**

- Mount points (other than the root itself), symlinks, automount triggers and non-local volumes are not
  entered; they appear as leaves of their kind. A directory already visited (by `(device, inode)`) is not
  walked again.
- Scanning `/` walks through the firmlinks as usual, then walks `/System/Volumes/Data` with the same
  visited set, so only folders that exist on the Data volume alone are added, grouped as such.
- Dataless directories are leaves.

**Protected and unreadable places**

- `~/Library/Containers/*` and `~/Library/Group Containers/*` are not entered by default. They appear as
  "not scanned" with their names, and can be scanned on request. Other protected folders (Desktop,
  Documents, Downloads, cloud storage) are scanned and may show the system's prompt once.
- Errors never stop a scan. They are attached to the directory and classified: no permission (`EACCES`),
  protected by macOS (`EPERM`), cloud only (`EDEADLK`), unavailable (`ETIMEDOUT`, `EIO`), other.
- A directory whose call takes longer than a few seconds is marked "slow" in the progress view, so the
  window shows where the scan waits; the other threads carry on.

**Numbers for a volume** come from the volume itself (`ATTR_VOL_SPACEUSED`, the capacity keys); a scan of a
volume's root shows how its total compares, with the difference named rather than hidden.

## Consequences

- The walker is low-level C-API code: unsafe pointer parsing of attribute buffers, careful descriptor
  handling. It gets thorough tests against generated trees (clones, hard links, sparse and compressed
  files, unreadable folders, deep paths, symlink loops).
- Nothing needs Full Disk Access. With it, fewer places show up as unreadable.
- A call that blocks forever keeps its thread. Enough of them would stall a scan; the "slow" marking makes
  that visible, and cancelling abandons those threads.
- Several questions can only be answered by running the app (see SCANNING.md, section 7); answers may amend
  this ADR.
