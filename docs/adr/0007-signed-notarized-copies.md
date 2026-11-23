# ADR-0007: Signed and notarized copies for sharing

Status: accepted, 2026-11-23

## Context

The app is built and installed locally (ADR-0001). A copy given to someone else arrives on their Mac
quarantined, by download or by message. Gatekeeper opens such a copy with the usual first-launch question
only if it is signed with a Developer ID and notarized by Apple; anything else needs a detour through
System Settings, which nobody should be taught to take. The Mac that opens it may be offline, so the
notarization ticket has to travel with the app.

Signing needs a Developer ID Application certificate with its private key; notarizing needs an App Store
Connect API key. Both are secrets, and the repository is public. If a key leaks, the certificate has to
be revoked, which can stop every copy signed with it from opening.

## Decision

- `Scripts/release.sh` makes the copy: a Release archive of a clean commit, stamped like `build.sh`
  stamps it, exported for Developer ID (Hardened Runtime, secure timestamp), notarized with `notarytool`,
  the ticket stapled to the app. That app goes into a disk image, with a link to `/Applications`, which
  is signed, notarized and stapled in turn, and into a zip. Before it reports success the script checks
  what a recipient gets the way Gatekeeper does: the disk image, the app in it, and the app unpacked from
  the zip.
- The credentials stay in the keychain of the Mac that makes the release: the signing identity, chosen
  by its fingerprint when more than one is installed, and a `notarytool` profile. None of it is in the
  repository.
- The certificate and the API key are used for this app only, so revoking either touches nothing else.
- Releases are made on a developer's Mac for now. Making them in GitHub Actions is a later step that
  amends this decision.

## Consequences

- A shared copy opens like any downloaded app, also offline, and also once it has been dragged out of
  the disk image, since the app carries its own ticket.
- Every release uploads twice to Apple (the app, then the disk image) and waits for the notary service,
  usually a minute or two each time.
- The certificate expires. Copies signed before that keep opening; new releases need a renewed one.
- The deployment target now decides who can open a shared copy, so raising it is no longer free
  (ADR-0001 let it follow the newest macOS).
- Sharing stays manual: no updates, no download page, no App Store.
