# Working in this repository

- The Xcode project lives one level down: `out-of-space-swiftly/out-of-space-swiftly.xcodeproj`. App
  sources are in `out-of-space-swiftly/out-of-space-swiftly/`, tests in
  `out-of-space-swiftly/out-of-space-swiftlyTests/`. Both folders are synchronized groups: a new file there
  is part of the target without touching the project file. The module name is `out_of_space_swiftly`.
- Build and test commands are in the README. Tests use Swift Testing. The app target defaults to
  `@MainActor` isolation; scanner code that runs off the main actor is marked `nonisolated`.
- xcodebuild's console output leaves out Swift Testing failure messages. Run tests with
  `-resultBundlePath build/tests.xcresult` and read them with
  `xcrun xcresulttool get test-results summary --path build/tests.xcresult`.
- Decisions are ADRs in `docs/adr/` (`ADR-NNNN: Title`, a status line, then Context, Decision,
  Consequences). A change that contradicts an ADR amends it or adds a new one. Keep the README's ADR list
  in step.
- No third-party dependencies (ADR-0001). Scanning follows ADR-0004; the facts behind it, with sources and
  confidence, are in `docs/SCANNING.md`. Add to that file when an experiment answers one of its open
  questions.
- The repository is public. Keep personal context, real paths and file names from the user's disk, scan
  output and secrets out of it. Test fixtures are trees generated in a temporary directory.
- Tests and debug runs never scan protected or personal locations (`~/Library`, Desktop, Documents,
  Downloads, cloud storage, other volumes) and never move real files to the Trash: point them at generated
  trees.
- Every pull request runs `.github/workflows/ci.yml` (job `build-and-test`, a required check on `main`).
  Actions are pinned by full commit SHA with a version comment; the repository only allows actions from
  GitHub's own organizations.
