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
  `Blocking` (`Support/Blocking.swift`): `Blocking.run` for one call with a timeout, `Blocking.startThread`
  and `Blocking.after` where several calls share one timeout (`Volumes.load`). Timeouts run on a serial
  queue of their own. Both at user-initiated priority.
- What the main actor does at once needs no look at the disk: making a `ScanTarget` from a URL, creating
  a `Scan`, starting it. The scan looks at its root on a thread of its own when it runs, and a root that
  takes long to answer shows among the folders that keep the scan waiting. The window can stop such a
  scan like any other.
- What the window can do without (the display name, the volume's figures, watching for changes) is asked
  for with a timeout, and the window goes on without it when the time is up.

## Consequences

- A call that never returns keeps its thread until the app quits. Nothing waits for it.
- A scan target's path is what the user chose, with symbolic links left in; the resolved path is the
  tree's (`ScanTree.rootPath`). Two windows on the same folder through different links do not know of
  each other.
- Acting on one item of a finished scan (move to the Trash, open, reveal in Finder) still runs on the main
  actor. The volume answered when it was scanned, but it may have stopped since.
