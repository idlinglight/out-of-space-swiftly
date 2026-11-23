# Release workflow

[release.yml](release.yml) runs when a tag `v<version>` is pushed, where `<version>` is the project's
`MARKETING_VERSION` (for example `v1.0`). It builds, signs and notarizes the app with
`Scripts/release.sh` and drafts a GitHub release with the disk image and the zip. A tag with a suffix
(`v1.0-rc1`) makes a prerelease instead; such a tag is also the way to try the workflow from a branch
before merging it. Drafts are published by hand.

These notes live next to the workflow rather than in it, so editing them does not start a run.

## Making a release

1. The version is `MARKETING_VERSION` in the project; change it in a pull request.
2. On `main`, after the merge: `git tag v1.0 && git push origin v1.0`.
3. Approve the run: Actions → the run → Review deployments (environment `release`).
4. Look at the draft release: download the disk image, open it, start the app. Then publish it.

A failed run keeps the script's logs and Apple's notary logs as the artifact `release-logs` for a week.
Delete a test tag and its draft release when done (`gh release delete v1.0-rc1 --cleanup-tag`).

## Environment `release`

- Required reviewer: the repository owner (self-review allowed, since nobody else could approve).
- Deployment branches and tags: tags matching `v*` only. Pull requests and branch pushes never reach
  the environment, so they never see its secrets.
- Secrets, all environment secrets (none at repository level):

  | Secret | Content |
  |---|---|
  | `MAC_CERT_P12` | The Developer ID Application certificate with its private key, exported as .p12 (the certificate row in Keychain Access, not the key alone), base64 |
  | `MAC_CERT_PASSWORD` | The password chosen at that export |
  | `APPLE_API_KEY` | The App Store Connect API key, the text of its `AuthKey_<id>.p8` (role "Developer" is enough) |
  | `APPLE_API_KEY_ID` | Its key ID |
  | `APPLE_API_ISSUER` | The issuer ID shown with the team keys |

  Set them from files, so no value passes through a terminal's history:

  ```sh
  base64 -i path/to/cert.p12 | gh secret set MAC_CERT_P12 --env release
  gh secret set MAC_CERT_PASSWORD --env release            # prompts for the value
  gh secret set APPLE_API_KEY --env release < path/to/AuthKey_<id>.p8
  gh secret set APPLE_API_KEY_ID --env release --body <id>
  gh secret set APPLE_API_ISSUER --env release --body <issuer id>
  ```

The certificate and the API key are used for this app only (ADR-0007), so replacing or revoking them
touches nothing else.

## How the job handles the credentials

- They go into a keychain made for the job with a random password, which the last steps delete, also
  after a failure. The .p12 and the .p8 exist as files only for the moment of the import.
- `security set-key-partition-list` gets that keychain's password (not the .p12's), so `codesign` can use
  the key without a prompt.
- A .p12 export holds only the certificate and its key. `codesign` also needs the intermediate that issued
  the certificate, Apple's "Developer ID Certification Authority" G2 (valid until 2031-09-17). The job
  downloads it from apple.com and checks it against the SHA-256 pinned in the workflow; it is the same
  file the certificate names as its issuer. A certificate from another intermediate needs a new URL and
  hash.
- The notary key becomes a `notarytool` profile in the job keychain; `OOSS_NOTARY_KEYCHAIN` points
  `release.sh` at it. The signing identity is the only one in the keychain, so the script picks it.
- Only GitHub's own actions, pinned by commit SHA (a repository setting). No caches: release runs are
  rare, and nothing restored from a cache should run next to the secrets.

## When something changes

- A new or renewed certificate: export it, replace `MAC_CERT_P12` and `MAC_CERT_PASSWORD`, and check that
  its issuer is still the G2 intermediate.
- Xcode or the runner: `runs-on` and `DEVELOPER_DIR` are the same as in [ci.yml](ci.yml); change both.
