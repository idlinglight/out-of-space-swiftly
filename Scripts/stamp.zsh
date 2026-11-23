# Sourced from the repository root by build.sh and release.sh: the stamp both put into the app.
# Sets commit, branch, count (the build number), dirty, date, note (one line describing the build) and
# stamp_settings: the xcodebuild arguments that carry the stamp into Info.plist (keys OOSSCommit and so
# on, shown in the About panel) and the commit count into CURRENT_PROJECT_VERSION.

commit=$(git rev-parse --short=7 HEAD)
branch=$(git branch --show-current)
[[ -n "$branch" ]] || branch=$(git describe --tags --exact-match 2>/dev/null || echo detached)  # a tag in CI
count=$(git rev-list --count HEAD)
dirty=0
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || dirty=1
date=$(date '+%Y-%m-%d %H:%M')

note="commit $commit on $branch, build $count"
[[ $dirty = 1 ]] && note="$note, with uncommitted changes"

stamp_settings=(
  CURRENT_PROJECT_VERSION="$count"
  OOSS_COMMIT="$commit" OOSS_BRANCH="$branch" OOSS_BUILD_DATE="$date" OOSS_DIRTY="$dirty"
)
