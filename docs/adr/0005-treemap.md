# ADR-0005: Treemap: squarified layout, drawn with Canvas, colored by content

Status: accepted, 2026-10-10

## Context

The treemap is the app's main view and has no library behind it (ADR-0001). It has to stay readable from a
volume's root down to a single folder, draw tens of thousands of tiles quickly, and answer the pointer
precisely. It should look like it belongs on macOS: quiet, with color reserved for what matters.

## Decision

**Layout** (`Treemap/TreemapLayout.swift`)

- Squarified (Bruls, Huizing, van Wijk 2000): tiles close to square, so sizes compare at a glance.
- Nested: a folder big enough gets padding and a header band with its name and size; its children are laid
  out below. Containers are subdivided breadth first, so a tile cap drops the deepest detail first.
- Children too small to draw (narrower than a few points) become one "remainder" tile per folder, with
  their count and total, instead of vanishing.
- The layout knows no model type: it asks a closure for children and works on any ID.
- It runs on the main actor for the zoom level and window size, with a cap of 40,000 tiles; it is
  recomputed when the zoom, the size or the tree changes.

**Drawing** (`Treemap/TreemapPanel.swift`)

- One `Canvas` draws all tiles; hover and selection outlines are a second, light canvas on top, so moving
  the pointer never redraws the tiles.
- Files are colored by what they contain (images, video, audio, archives and disk images, documents,
  code and data, applications, other), looked up once per name extension through Uniform Type
  Identifiers. Folders are quiet greys alternating by depth; remainders are fainter still.
- Labels only where they fit: folder headers, and file names on tiles big enough to hold one.

**Interaction**

- The zoom level fills the view. Hovering names an item in the status bar; a click selects (shared with
  the outline and the inspector); a double-click zooms one level towards the item; the path bar and Zoom
  Out (⌘↑) go back up. The context menu acts on the item under the pointer.

## Consequences

- Very large folders at deep zoom levels show remainders rather than every file; the outline lists them
  all.
- Live window resizing recomputes the layout each frame; if that proves too slow on large trees, the
  next step is scaling the last layout during the resize and laying out again when it ends.
- Coloring by name extension misses files without one (shown as "other"); content sniffing would cost
  disk reads, which a scanner should not do.
