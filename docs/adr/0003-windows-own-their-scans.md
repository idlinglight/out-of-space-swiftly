# ADR-0003: Each window owns its scan

Status: accepted, 2026-10-10

## Context

Looking at more than one folder at a time is useful: two volumes side by side, or a project folder next to
the caches it fills. Supporting that later is hard if scan state lives in one app-wide model, so the shape
has to be right from the start.

## Decision

- A window shows one scan root. Its scan (tree, progress, selection, zoom path) belongs to that window,
  in a per-window model. Nothing about a scan is app-global.
- Windows are opened for a scan root (`WindowGroup(for:)` with a value that identifies the root), so
  "open in new window" and window restoration fall out of the scene system.
- The scanner is UI-independent: it takes a root and options and produces a tree and progress. Several
  scans can run at once; each window cancels its own when it closes.
- App-wide state is limited to what really is shared: preferences, the list of volumes, recent roots.

## Consequences

- Two windows on overlapping folders scan independently and may hold the same subtree twice. That is
  accepted for now; sharing scan results between windows can come later behind the scanner's interface.
- Window-specific commands (rescan, zoom out, reveal, move to trash) act on the key window's model, through
  focused scene values rather than a global selection.
- Running several scans at once divides the disk's throughput; the scanner should keep its thread count
  bounded per scan and overall.
