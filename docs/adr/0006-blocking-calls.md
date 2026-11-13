# ADR-0006: Calls that can block run on threads of their own

Status: accepted, 2026-11-13

## Context

Anything that asks a volume can take a long time: a disk that has to spin up, a network mount that went
away, a volume so full that it has become slow, a privacy check (docs/SCANNING.md). That holds for the
small calls as well: a display name, "is this a folder", resolving symbolic links, a volume's figures.

Three places are wrong for such a call:

- The main actor: the app stops responding for as long as the call takes.
- Swift's cooperative pool: it has one thread per core and no spare for one that is stuck.
- GCD's global queues: they get no further thread while as many threads as there are cores are running, so
  in a busy process the call starts late, and a timeout on such a queue fires late (measured,
  docs/SCANNING.md, section 1).

The scanner already walks directories on dedicated threads (ADR-0004). The window code did not follow
suit: it resolved the chosen folder, read its display name, created the scan (which looked at the root)
and listed the mount points on the main actor.

## Decision

- A call that asks the file system about a place that may not answer runs on a thread of its own, through
  `Blocking` (`Support/Blocking.swift`): `Blocking.run` for one call, with a timeout where something is
  held up for the answer and without one where it is not; `Blocking.startThread` and `Blocking.after`
  where several calls share one timeout (`Volumes.overview`). Timeouts run on a serial queue of their own.
  Both at user-initiated priority.
- What the main actor does at once needs no look at the disk: making a `ScanTarget` from a URL, creating
  a `Scan`, starting it. The scan looks at its root on a thread of its own when it runs, and a root that
  takes long to answer shows among the folders that keep the scan waiting. The window can stop such a
  scan like any other.
- Watching the root for changes starts on that same thread, once the root is known and before anything in
  it is read, so that no change falls between the scan and the watch (ADR-0004).
- What the window can do without (the display name, the volume's figures) is asked for without a timeout
  and used when it comes.
- The start view waits three seconds for the volumes. One that has not answered three seconds after it was
  asked is listed as not responding, without figures, and gets them when it answers; it can be scanned
  all the same. If the list of volumes is not there after three seconds, the view says so. The volumes are
  ordered by their mount points, so a row keeps its place when its volume answers.

## Consequences

- A call that never returns keeps its thread until the app quits. Nothing is held up by it.
- Every start view asks the volumes for itself. With a volume that never answers, each one leaves a thread
  behind.
- A scan target's path is what the user chose, with symbolic links left in; the resolved path is the
  tree's (`ScanTree.rootPath`). Two windows on the same folder through different links do not know of
  each other.
- Making a file URL from a path asks the disk whether it is a folder unless the call says so
  (`isDirectory:`, `directoryHint:`). On the main actor, say so.
- Every scan starts one more short-lived thread than it has scanning threads, background refreshes
  included.
- Acting on one item of a finished scan (move to the Trash, open, reveal in Finder) still runs on the main
  actor. The volume answered when it was scanned, but it may have stopped since.
