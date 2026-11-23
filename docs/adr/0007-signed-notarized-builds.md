# ADR-0007: Signed and notarized builds

Status: provisional, 2026-11-23. It covers builds made on a developer's Mac and is rewritten when GitHub
Actions makes the releases.

## Context

The app is built locally (ADR-0001), but people should be able to try it without building it. A copy
that is downloaded or sent arrives on their Mac quarantined, and Gatekeeper opens it only if it is signed
with a Developer ID and notarized by Apple. Anything else is refused: depending on how it was signed,
macOS offers at most a detour through System Settings, or reports the app as damaged. Without a signed
build, trying the app means cloning the repository and building it with Xcode, which is too much to ask
of someone who only wants to try it. The Mac that opens a build may be offline, so the notarization
ticket has to travel with the app.

Signing needs a Developer ID Application certificate with its private key; notarizing needs an App Store
Connect API key. Both are secrets, and the repository is public. If a key leaks, the certificate has to
be revoked, which can stop every build signed with it from opening.

## Decision

- `Scripts/release.sh` makes the build: a Release archive of a clean commit, stamped like `build.sh`
  stamps it, exported for Developer ID (Hardened Runtime, secure timestamp), notarized with `notarytool`,
  the ticket stapled to the app. That app goes into a disk image, with a link to `/Applications`, which
  is signed, notarized and stapled in turn, and into a zip. Before it reports success the script checks
  what a recipient gets the way Gatekeeper does: the disk image, the app in it, and the app unpacked from
  the zip.
- The credentials stay in the keychain of the Mac that makes the build: the signing identity, chosen by
  its fingerprint when more than one is installed, and a `notarytool` profile. None of it is in the
  repository.
- The certificate and the API key are used for this app only, so revoking either touches nothing else.
- The next step: GitHub Actions runs the same script for a version tag and publishes the disk image and
  the zip as a GitHub Release. This ADR is rewritten then.

## Consequences

- A build opens like any downloaded app, also offline, and also once it has been dragged out of the disk
  image, since the app carries its own ticket.
- Every build is uploaded twice to Apple (the app, then the disk image) and waits for the notary service,
  usually a minute or two each time.
- The certificate expires. Builds signed before that keep opening; new ones need a renewed certificate.
- Who can open a build depends on the deployment target (ADR-0001).
- No updater and no App Store. Until the GitHub Releases exist, builds are handed over by hand.
