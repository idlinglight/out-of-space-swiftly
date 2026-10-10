# Out Of Space Swiftly

A macOS app that shows where the space on a disk went: it scans a folder or volume and draws the result
as a treemap, natively, with Apple's frameworks and nothing else.

Built locally, not distributed.

## What it does

- Start with a folder: Choose Folder…, Home Folder, drop one on the window, or click a disk in the
  list, which shows each mounted volume's used, purgeable and free space.
- The scan shows what it has found and where it is reading; folders that keep it waiting are named.
- The result is a treemap of the folder: every file a rectangle sized by the space it takes on disk,
  colored by what it holds (images, video, audio, archives, documents, code, applications). Folders nest
  inside with their name and size; a chain of single folders shares one header.
- Hover to see an item in the status bar, click to select it, double-click to zoom in one level; the path
  bar and Zoom Out (⌘↑) go back up. The outline beside the treemap lists the same level, sortable by name,
  size or item count, and shares the selection.
- The inspector shows the selection's size, place and anything special about it (a clone, a cloud-only
  folder, a folder macOS protects, one that could not be read). For a whole volume it compares what the
  scan found with what the volume says it uses.
- Show in Finder, Copy Path and Move to Trash (after asking) from the inspector, the context menu or the
  Scan menu.
- Files changed on disk after the scan are picked up: the folders concerned are scanned again in the
  background.
- Every window has its own scan (⌘N for another); windows come back with their folder after a relaunch.

Scanning reads only metadata. It counts space on disk (hard links and clones once), does not enter other
volumes, cloud-only folders or other apps' containers, and does not download anything from the cloud;
see [docs/SCANNING.md](docs/SCANNING.md).

## Requirements

- macOS 26, Xcode 27.
- No third-party dependencies.

## Build, run, test

Open `out-of-space-swiftly/out-of-space-swiftly.xcodeproj` in Xcode and run the `out-of-space-swiftly`
scheme.

From a shell:

```sh
xcodebuild -project out-of-space-swiftly/out-of-space-swiftly.xcodeproj -scheme out-of-space-swiftly -configuration Debug build
xcodebuild -project out-of-space-swiftly/out-of-space-swiftly.xcodeproj -scheme out-of-space-swiftly -configuration Debug test -destination 'platform=macOS'
```

`Scripts/build.sh` makes a Release build stamped with the commit it came from; `Scripts/build.sh --install`
also replaces `~/Applications/out-of-space-swiftly.app` with it and launches it.

Debug builds can be driven from a shell (scan a folder, zoom, select, write a snapshot of the window and
quit) through `OOSS_*` environment variables; see `Support/DebugAids.swift`.

Pull requests are built and tested by GitHub Actions ([ci.yml](.github/workflows/ci.yml)) on the hosted
`xcode-27` runner, signed ad hoc since CI has no certificates.

## Scanning

[docs/SCANNING.md](docs/SCANNING.md) collects what a disk scanner on macOS has to know: fast enumeration,
which size to count, clones and hard links, firmlinks, cloud files, and the privacy protections that can
stall a scan.

## Design decisions

Recorded as ADRs in [docs/adr](docs/adr):

- [0001](docs/adr/0001-native-macos-app.md) Native macOS app without third-party dependencies
- [0002](docs/adr/0002-sandbox-off-for-now.md) App Sandbox off for now; Hardened Runtime on
- [0003](docs/adr/0003-windows-own-their-scans.md) Each window owns its scan
- [0004](docs/adr/0004-scanning.md) Scanning with our own getattrlistbulk walker
- [0005](docs/adr/0005-treemap.md) Treemap: squarified layout, drawn with Canvas, colored by content

## License

[0BSD](LICENSE): use it however you like, no attribution required. Much of this code was written together
with an AI coding agent (see the commit trailers); a license without conditions means nobody has to work
out where human authorship begins and ends.
