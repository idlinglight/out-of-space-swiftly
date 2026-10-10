# Out Of Space Swiftly

A macOS app that shows where the space on a disk went: it scans a folder or volume and draws the result
as a treemap, natively, with Apple's frameworks and nothing else.

Early days: the first version is being built. Built locally, not distributed.

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

## License

[0BSD](LICENSE): use it however you like, no attribution required. Much of this code was written together
with an AI coding agent (see the commit trailers); a license without conditions means nobody has to work
out where human authorship begins and ends.
