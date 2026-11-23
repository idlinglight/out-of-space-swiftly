# ADR-0007: Signed and notarized builds

Status: accepted, 2026-11-23; replaces the provisional version of the same day, which covered only builds
made on a developer's Mac

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

- `Scripts/release.sh` makes a build: a Release archive of a clean commit, stamped like `build.sh`
  stamps it, exported for Developer ID (Hardened Runtime, secure timestamp), notarized with `notarytool`,
  the ticket stapled to the app. That app goes into a disk image, with a link to `/Applications`, which
  is signed, notarized and stapled in turn, and into a zip. Before it reports success the script checks
  what a recipient gets the way Gatekeeper does: the disk image, the app in it, and the app unpacked from
  the zip.
- Releases come from GitHub Actions. Pushing a tag `v<version>` runs `.github/workflows/release.yml`,
  which waits for approval in the protected environment `release`, runs the script and drafts a GitHub
  Release with the disk image and the zip. The draft is published by hand. A tag with a suffix makes a
  prerelease, which is also how the workflow is tried from a branch.
- The credentials are never in the repository. In CI they are secrets of the `release` environment,
  which only `v*` tags reach; the job imports them into a keychain of its own and deletes it at the end.
  On a developer's Mac they are in the keychain, where the script also runs, to try a change to it
  without a release.
- The certificate and the API key are used for this app only, so revoking either touches nothing else.

## Consequences

- A build opens like any downloaded app, also offline, and also once it has been dragged out of the disk
  image, since the app carries its own ticket.
- Every build is uploaded twice to Apple (the app, then the disk image) and waits for the notary service,
  usually a minute or two each time.
- A release needs the owner twice: to approve the run and to publish the draft.
- The certificate's private key lives in two places, the owner's keychain and the environment's secrets;
  a leak from either means revoking it.
- The certificate expires. Builds signed before that keep opening; new releases need a renewed
  certificate and new secrets.
- Who can open a build depends on the deployment target (ADR-0001).
- No updater and no App Store: new versions show up on the Releases page only.
