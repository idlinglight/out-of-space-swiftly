# ADR-0001: Native macOS app without third-party dependencies

Status: accepted, 2026-10-10

## Context

The app shows where the space on a disk went: it scans a folder or volume and draws the result as a
treemap. Doing that well on a Mac means working with what macOS does to a scanner: APFS volume groups and
firmlinks, clones and hard links, cloud files that exist only as placeholders, and privacy protections that
can stall a file system call. Those are platform questions, best answered with the platform's own APIs.

The app runs on its user's Macs. It is not distributed through the App Store, and signed or notarized
releases are out of scope for now.

## Decision

- A SwiftUI app for macOS 26 and later, written in Swift 6. No other platforms.
- No third-party dependencies: Apple frameworks and the system's C APIs only. Adding one needs its own ADR.
- The treemap (layout and drawing) is our own code.
- Built and installed locally with `Scripts/build.sh`, which stamps the commit into the app.

## Consequences

- Building needs only Xcode. There is no package resolution step and no lockfile to keep current.
- No Windows or Linux version; the scanner may use macOS-only system calls freely.
- Everything about layout, drawing and interaction has to be built, which is also a chance to find a
  look that fits the platform rather than a library's defaults.
- The deployment target can follow the newest macOS; the CI runner only has to match it.
