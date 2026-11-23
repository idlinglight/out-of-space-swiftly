#!/bin/zsh
# Makes a build of the app for others to run: a Release archive of the current commit, stamped as build.sh
# stamps it, signed with a Developer ID and notarized by Apple, as a disk image and as a zip:
#
#   Scripts/release.sh
#     -> build/release/<version>-<build>-<commit>/Out-Of-Space-Swiftly-<version>-<build>.dmg and .zip
#
# It needs a clean working tree and two things in the keychain, neither of which is in the repository:
# - A "Developer ID Application" identity of the project's team. With more than one installed, choose one
#   by its SHA-1 fingerprint (`security find-identity -v -p codesigning` lists them):
#   OOSS_SIGNING_IDENTITY=<SHA-1>, or once per clone `git config ooss.signingIdentity <SHA-1>`.
# - A notarytool profile named out-of-space-swiftly, made once from an App Store Connect API key:
#     xcrun notarytool store-credentials out-of-space-swiftly \
#       --key AuthKey_<key id>.p8 --key-id <key id> --issuer <issuer id>
#   Another name: OOSS_NOTARY_PROFILE=<name>, or once per clone `git config ooss.notaryProfile <name>`.
#   The profile is looked up in the default keychains, or in the keychain at OOSS_NOTARY_KEYCHAIN if set.
# GitHub Actions (.github/workflows/release.yml) puts both into a keychain of its own for the job.
#
# The app is notarized and its ticket stapled to it, so a copy taken out of the disk image or the zip
# opens on its own, also offline. The disk image (the app and a link to /Applications) is signed,
# notarized and stapled as well. Each upload to Apple's notary service usually takes a minute or two.
# Before it reports success, the script checks what a recipient gets as Gatekeeper would: the disk image,
# the app in it, and the app unpacked from the zip with plain unzip. The archive (with the dSYMs), the
# logs and Apple's notary logs stay next to the results.
set -euo pipefail

cd "$(dirname "$0")/.."
project=out-of-space-swiftly/out-of-space-swiftly.xcodeproj
scheme=out-of-space-swiftly

# Messages may carry log text, so print takes them raw (-r), without acting on backslashes.
fail() { print -ru2 -- "$*"; exit 1; }

xcode_failed() {  # step, log
  print -ru2 -- "$1 failed. Errors:"
  { grep -E 'error:' "$2" || true; } | sed 's/^ *//' | sort -u | head -20 >&2
  fail "Full log: $2"
}

# Without extended attributes: ditto would keep them in "._" files, which every unzip tool but Finder's
# leaves in the bundle as extra files that break the signature. A signed app needs none of them.
zip_app() { ditto -c -k --norsrc --noextattr --noacl --keepParent "$1" "$2"; }

# Uploads $1 to the notary service and waits for the verdict. Apple's log goes to notary-$2.json.
notarize() {
  local submission verdict issues
  xcrun notarytool submit "$1" "${notary[@]}" --wait --timeout 1h \
    --output-format json > "$out/notary-$2-submit.json" 2> "$out/notarytool.log" || true
  submission=$(jq -r '.id // empty' "$out/notary-$2-submit.json" 2>/dev/null || true)
  [[ -n "$submission" ]] || fail "The upload of $1 to the notary service failed: $(<"$out/notarytool.log")"
  verdict=$(jq -r '.status // empty' "$out/notary-$2-submit.json")
  xcrun notarytool log "$submission" "${notary[@]}" "$out/notary-$2.json" > /dev/null 2>&1 || true
  issues=$(jq -r '.issues[]? | "  \(.path // "-"): \(.message)"' "$out/notary-$2.json" 2>/dev/null || true)
  if [[ "$verdict" != Accepted ]]; then
    [[ -z "$issues" ]] || print -ru2 -- "$issues"
    fail "Notarization of $1: ${verdict:-no result} (submission $submission). Apple's log: $out/notary-$2.json"
  fi
  [[ -z "$issues" ]] || print -rl -- "Accepted, with notes from Apple:" "$issues"
}

staple() { xcrun stapler staple "$1" > "$out/stapler.log" 2>&1 || fail "Stapling $1 failed: $(<"$out/stapler.log")"; }

# Fails unless Gatekeeper's assessment ($1) names a notarized Developer ID signature; $2 says of what.
expect_notarized() {
  [[ "$1" == *'source=Notarized Developer ID'* ]] || fail "Gatekeeper does not accept $2 as notarized: $1"
}

# Checks the app at $1 as Gatekeeper on another Mac would; $2 says where it came from.
check_app() {
  local assessment
  xcrun stapler validate "$1" > /dev/null 2>&1 || fail "The app $2 has no valid ticket."
  codesign --verify --deep --strict "$1" 2> "$out/codesign.log" \
    || fail "The signature of the app $2 does not verify: $(<"$out/codesign.log")"
  assessment=$(spctl --assess --type execute --verbose=2 "$1" 2>&1 || true)
  expect_notarized "$assessment" "the app $2"
}

[[ -z "$(git status --porcelain)" ]] || fail "The working tree has changes (see git status); a release is made from a commit."

source Scripts/stamp.zsh

settings=$(xcodebuild -project "$project" -scheme "$scheme" -configuration Release -showBuildSettings 2>/dev/null)
setting() { sed -n "/^ *$1 = /{s///p;q;}" <<< "$settings"; }
name=$(setting PRODUCT_NAME)
version=$(setting MARKETING_VERSION)
team=$(setting DEVELOPMENT_TEAM)
[[ -n "$name" && -n "$version" && -n "$team" ]] \
  || fail "Could not read PRODUCT_NAME, MARKETING_VERSION and DEVELOPMENT_TEAM from the project."

# The team's Developer ID Application identities, by SHA-1 fingerprint.
identities=(${(fu)"$(security find-identity -v -p codesigning \
  | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"Developer ID Application: .* ($team)\"\$/\1/p")"})
identity=${(U)${OOSS_SIGNING_IDENTITY:-$(git config --get ooss.signingIdentity || true)}}
if [[ -z "$identity" ]]; then
  case ${#identities} in
    0) fail "There is no Developer ID Application identity of team $team in the keychain." ;;
    1) identity=${identities[1]} ;;
    *) fail "There are several Developer ID Application identities of team $team: ${identities[*]}
Choose one with OOSS_SIGNING_IDENTITY=<SHA-1>, or once for this clone: git config ooss.signingIdentity <SHA-1>" ;;
  esac
elif (( ! ${identities[(Ie)$identity]} )); then
  fail "$identity is not a valid Developer ID Application identity of team $team in the keychain."
fi
profile=${OOSS_NOTARY_PROFILE:-$(git config --get ooss.notaryProfile || echo out-of-space-swiftly)}
notary=(--keychain-profile "$profile")
[[ -z "${OOSS_NOTARY_KEYCHAIN:-}" ]] || notary+=(--keychain "$OOSS_NOTARY_KEYCHAIN")

# The commit in the folder name keeps a release of another commit with the same build number (the same
# commit count on another branch) from replacing this one.
out=build/release/$version-$count-$commit
archive=$out/$name.xcarchive
exported=$out/export
app=$exported/$name.app
base=$out/${name// /-}-$version-$count
mount=$out/mount
detach_image() { hdiutil detach "$mount" -force > /dev/null 2>&1 || true; }
[[ ! -d "$mount" ]] || detach_image  # left attached by an earlier run of this commit that was killed
rm -rf "$out"
mkdir -p "$out"

echo "Releasing $name $version ($count): $note"
echo "Signing identity $identity, notary profile $profile"
git merge-base --is-ancestor HEAD origin/main 2>/dev/null \
  || echo "Note: $commit is not on origin/main (as last fetched), so the public repository may not have the commit this copy names."

# Fail before the build, not after it, if the notary credentials do not work.
xcrun notarytool history "${notary[@]}" > /dev/null 2> "$out/notarytool.log" \
  || fail "The notary profile '$profile' does not work: $(<"$out/notarytool.log")"

echo "Archiving"
xcodebuild archive -project "$project" -scheme "$scheme" -configuration Release -archivePath "$archive" \
  "${stamp_settings[@]}" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
  > "$out/archive.log" 2>&1 || xcode_failed Archiving "$out/archive.log"

echo "Exporting for Developer ID"
cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>destination</key>
	<string>export</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>$identity</string>
	<key>teamID</key>
	<string>$team</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$exported" \
  -exportOptionsPlist "$out/ExportOptions.plist" > "$out/export.log" 2>&1 || xcode_failed Exporting "$out/export.log"
[[ -d "$app" ]] || fail "The export has no app at $app"

echo "Checking the signature"
codesign --verify --deep --strict "$app" 2> "$out/codesign.log" || fail "The signature does not verify: $(<"$out/codesign.log")"
details=$(codesign -d --verbose=2 "$app" 2>&1) || fail "Could not read the app's signature: $details"
codesign -d --extract-certificates="$out/signer-" "$app" 2> "$out/codesign.log" \
  || fail "Could not extract the app's certificates: $(<"$out/codesign.log")"
signer=$(shasum -a 1 < "$out/signer-0" | cut -d' ' -f1)
rm -f -- "$out"/signer-*(N)
[[ ${(U)signer} == "$identity" ]] || fail "The app is signed by $signer, not by $identity."
[[ "$details" == *$'\n'Timestamp=* ]] || fail "The signature has no secure timestamp."
[[ "$details" == *'(runtime)'* ]] || fail "The signature does not enable the Hardened Runtime."
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)
[[ "$entitlements" != *get-task-allow* ]] || fail "The app has the get-task-allow entitlement, which notarization refuses."
stamped=$(plutil -extract OOSSCommit raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)
[[ "$stamped" == "$commit" ]] || fail "The app carries no stamp (got '$stamped')."

echo "Notarizing the app"
zip_app "$app" "$out/upload.zip"
notarize "$out/upload.zip" app
rm -f "$out/upload.zip"
staple "$app"

zip_app "$app" "$base.zip"

echo "Making the disk image"
# hdiutil create, attach and detach print deprecation warnings on macOS 27 that point to `diskutil image`
# and `diskutil eject`; their output goes to hdiutil.log. They still work, and the replacement does not
# yet seem to do everything hdiutil does, so the switch waits until a macOS release drops them.
staging=$out/dmg
mkdir "$staging"
ditto "$app" "$staging/$name.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "$name" -srcfolder "$staging" -fs HFS+ -format UDZO "$base.dmg" > "$out/hdiutil.log" 2>&1 \
  || fail "Making the disk image failed: $(<"$out/hdiutil.log")"
rm -rf "$staging"
codesign --sign "$identity" --timestamp "$base.dmg" 2> "$out/codesign.log" \
  || fail "Signing the disk image failed: $(<"$out/codesign.log")"

echo "Notarizing the disk image"
notarize "$base.dmg" dmg
staple "$base.dmg"

echo "Checking the copy in the zip"
check=$out/check
unzip -q "$base.zip" -d "$check"
check_app "$check/$name.app" "in the zip"
rm -rf "$check"

echo "Checking the disk image"
xcrun stapler validate "$base.dmg" > /dev/null 2>&1 || fail "The disk image has no valid ticket."
expect_notarized "$(spctl --assess --type open --context context:primary-signature --verbose=2 "$base.dmg" 2>&1 || true)" \
  "the disk image"
mkdir "$mount"
# zsh runs EXIT traps on exit and on errors, but not when a signal ends the script.
trap detach_image EXIT
trap 'detach_image; exit 130' INT TERM HUP
hdiutil attach "$base.dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount" > /dev/null 2>> "$out/hdiutil.log" \
  || fail "Mounting the disk image failed: $(<"$out/hdiutil.log")"
check_app "$mount/$name.app" "in the disk image"
[[ "$(readlink "$mount/Applications")" == /Applications ]] || fail "The disk image lacks its link to /Applications."
hdiutil detach "$mount" > /dev/null 2>> "$out/hdiutil.log" || fail "Detaching the disk image failed: $(<"$out/hdiutil.log")"
trap - EXIT INT TERM HUP
rmdir "$mount" 2>/dev/null || true

echo "Released $name $version ($count), $note"
for result in "$base.dmg" "$base.zip"; do
  echo "  $result"
  echo "    SHA-256 $(shasum -a 256 "$result" | cut -d' ' -f1)"
done
