#!/bin/zsh
# Builds a Release copy of the app stamped with the commit it was made from, into build/, and with
# --install replaces ~/Applications/out-of-space-swiftly.app with it and launches it.
#
#   Scripts/build.sh            build only; prints where the app is
#   Scripts/build.sh --install  build, then install into ~/Applications and launch
#
# The stamp (commit, branch, uncommitted-changes flag, date) lands in Info.plist through build settings
# and shows in the About panel. The build number is the commit count. Nothing is installed unless the
# build succeeded and the stamp is verified in the product.
set -euo pipefail

cd "$(dirname "$0")/.."
project=out-of-space-swiftly/out-of-space-swiftly.xcodeproj
scheme=out-of-space-swiftly
out=build

commit=$(git rev-parse --short=7 HEAD)
branch=$(git branch --show-current)
[[ -n "$branch" ]] || branch=detached
count=$(git rev-list --count HEAD)
dirty=0
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || dirty=1
date=$(date '+%Y-%m-%d %H:%M')

note="commit $commit on $branch, build $count"
[[ $dirty = 1 ]] && note="$note, with uncommitted changes"
echo "Building $scheme (Release): $note"

mkdir -p "$out"
log="$out/xcodebuild.log"
if ! xcodebuild -project "$project" -scheme "$scheme" -configuration Release build \
    CURRENT_PROJECT_VERSION="$count" \
    OOSS_COMMIT="$commit" OOSS_BRANCH="$branch" OOSS_BUILD_DATE="$date" OOSS_DIRTY="$dirty" \
    > "$log" 2>&1; then
  echo "Build failed. Errors:"
  grep -E 'error:' "$log" | sed 's/^ *//' | sort -u | head -20
  echo "Full log: $log"
  exit 1
fi

products=$(xcodebuild -project "$project" -scheme "$scheme" -configuration Release -showBuildSettings 2>/dev/null \
  | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)
built="$products/$scheme.app"
[[ -d "$built" ]] || { echo "No app at $built"; exit 1; }

app="$out/$scheme.app"
rm -rf "$app"
ditto "$built" "$app"

plist="$app/Contents/Info.plist"
stamped=$(plutil -extract OOSSCommit raw -o - "$plist" 2>/dev/null || true)
[[ "$stamped" == "$commit" ]] || { echo "The build carries no stamp (got '$stamped'); not installing."; exit 1; }
version=$(plutil -extract CFBundleShortVersionString raw -o - "$plist")
echo "Built $app: version $version ($count), $note"

if [[ "${1:-}" == "--install" ]]; then
  target="$HOME/Applications/$scheme.app"
  mkdir -p "$HOME/Applications"
  # Match the executable path: process names are cut to 16 characters, too short for this one.
  running="/$scheme.app/Contents/MacOS/$scheme\$"
  if pgrep -fq "$running"; then
    echo "Quitting the running $scheme"
    osascript -e "tell application \"$scheme\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do pgrep -fq "$running" || break; sleep 0.5; done
    pgrep -fq "$running" && pkill -f "$running" || true
  fi
  rm -rf "$target"
  ditto "$app" "$target"
  echo "Installed $target"
  open "$target"
fi
