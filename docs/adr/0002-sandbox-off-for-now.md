# ADR-0002: App Sandbox off for now; Hardened Runtime on

Status: accepted, 2026-10-10

## Context

A disk usage scanner wants to read the metadata of everything under the folder it is pointed at. Under the
App Sandbox it may only read what the user hands it: a folder chosen in an open panel or dropped on the
window, remembered across launches with a security-scoped bookmark. How far such a grant reaches into
protected subfolders (other apps' containers, cloud storage, Desktop and Documents) is not documented
clearly and would have to be found out by experiment.

Without the sandbox the app can read what the user's account can, and the system's privacy protections
(TCC) still apply in full: protected locations prompt or fail just the same. The sandbox does not make
scanning safer for the user's data; the app only reads metadata either way.

## Decision

- App Sandbox off. Hardened Runtime on.
- The app still offers a folder picker and drag and drop as the main way to choose what to scan, so the
  interaction would not change much under the sandbox.
- Debug builds are signed with the development team, so privacy grants survive rebuilds.

## Consequences

- Scanning, testing and debugging start without the open questions a sandbox would add.
- A sandboxed build stays a medium-term target. Getting there needs: scan roots as security-scoped
  bookmarks, a check of what a picked folder covers, and a decision for roots the user did not pick (the
  volumes overview, rescans after a relaunch).
- Code that touches scan roots should go through one place, so that place can later hold the bookmarks.
