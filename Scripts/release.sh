#!/bin/zsh
# Makes a copy of the app to give to others: a Release archive of the current commit, stamped as build.sh
# stamps it, signed with a Developer ID, notarized by Apple with the ticket stapled to the app, and zipped.
#
#   Scripts/release.sh   ->   build/release/<version>-<build>/Out-Of-Space-Swiftly-<version>-<build>.zip
#
# It needs a clean working tree and two things in the keychain, neither of which is in the repository:
# - A "Developer ID Application" identity of the project's team. With more than one installed, choose one
#   by its SHA-1 fingerprint (`security find-identity -v -p codesigning` lists them):
#   OOSS_SIGNING_IDENTITY=<SHA-1>, or once per clone `git config ooss.signingIdentity <SHA-1>`.
# - A notarytool profile named out-of-space-swiftly, made once from an App Store Connect API key:
#     xcrun notarytool store-credentials out-of-space-swiftly \
#       --key AuthKey_<key id>.p8 --key-id <key id> --issuer <issuer id>
#   Another name: OOSS_NOTARY_PROFILE=<name>, or once per clone `git config ooss.notaryProfile <name>`.
#
# The app is uploaded to Apple's notary service, which usually answers within minutes. The archive (with
# the dSYMs), the logs and Apple's notary log stay next to the zip. Before it reports success, the script
# unpacks the zip with plain unzip and checks the copy inside as Gatekeeper would.
set -euo pipefail

cd "$(dirname "$0")/.."
project=out-of-space-swiftly/out-of-space-swiftly.xcodeproj
scheme=out-of-space-swiftly

fail() { print -u2 -- "$*"; exit 1; }

# Without extended attributes: ditto would keep them in "._" files, which every unzip tool but Finder's
# leaves in the bundle as extra files that break the signature. A signed app needs none of them.
zip_app() { ditto -c -k --norsrc --noextattr --noacl --keepParent "$1" "$2"; }

xcode_failed() {  # step, log
  print -u2 -- "$1 failed. Errors:"
  grep -E 'error:' "$2" | sed 's/^ *//' | sort -u | head -20 >&2
  fail "Full log: $2"
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

out=build/release/$version-$count
archive=$out/$name.xcarchive
exported=$out/export
app=$exported/$name.app
zip=$out/${name// /-}-$version-$count.zip
rm -rf "$out"
mkdir -p "$out"

echo "Releasing $name $version ($count): $note"
echo "Signing identity $identity, notary profile $profile"

# Fail before the build, not after it, if the notary credentials do not work.
xcrun notarytool history --keychain-profile "$profile" > /dev/null 2> "$out/notarytool.log" \
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
details=$(codesign -d --verbose=2 "$app" 2>&1)
codesign -d --extract-certificates="$out/signer-" "$app" 2>/dev/null
signer=$(shasum -a 1 < "$out/signer-0" | cut -d' ' -f1)
rm -f -- "$out"/signer-*(N)
[[ ${(U)signer} == "$identity" ]] || fail "The app is signed by $signer, not by $identity."
[[ "$details" == *$'\n'Timestamp=* ]] || fail "The signature has no secure timestamp."
[[ "$details" == *'(runtime)'* ]] || fail "The signature does not enable the Hardened Runtime."
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)
[[ "$entitlements" != *get-task-allow* ]] || fail "The app has the get-task-allow entitlement, which notarization refuses."
stamped=$(plutil -extract OOSSCommit raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)
[[ "$stamped" == "$commit" ]] || fail "The app carries no stamp (got '$stamped')."

echo "Notarizing (waiting for Apple's notary service)"
zip_app "$app" "$out/upload.zip"
xcrun notarytool submit "$out/upload.zip" --keychain-profile "$profile" --wait --timeout 1h \
  --output-format json > "$out/notary-submit.json" 2> "$out/notarytool.log" || true
rm -f "$out/upload.zip"
submission=$(jq -r '.id // empty' "$out/notary-submit.json" 2>/dev/null || true)
[[ -n "$submission" ]] || fail "The upload to the notary service failed: $(<"$out/notarytool.log")"
verdict=$(jq -r '.status // empty' "$out/notary-submit.json")
xcrun notarytool log "$submission" --keychain-profile "$profile" "$out/notary-log.json" > /dev/null 2>&1 || true
issues=$(jq -r '.issues[]? | "  \(.path // "-"): \(.message)"' "$out/notary-log.json" 2>/dev/null || true)
if [[ "$verdict" != Accepted ]]; then
  [[ -z "$issues" ]] || print -u2 -- "$issues"
  fail "Notarization: ${verdict:-no result} (submission $submission). Apple's log: $out/notary-log.json"
fi
[[ -z "$issues" ]] || print -- "Accepted, with notes from Apple:\n$issues"

echo "Stapling the ticket"
xcrun stapler staple "$app" > "$out/stapler.log" 2>&1 || fail "Stapling failed: $(<"$out/stapler.log")"

zip_app "$app" "$zip"

echo "Checking the copy in the zip"
check=$out/check
unzip -q "$zip" -d "$check"
received=$check/$name.app
xcrun stapler validate "$received" > /dev/null 2>&1 || fail "The app in the zip has no valid ticket."
codesign --verify --deep --strict "$received" 2> "$out/codesign.log" \
  || fail "The signature of the app in the zip does not verify: $(<"$out/codesign.log")"
assessment=$(spctl --assess --type execute --verbose=2 "$received" 2>&1) \
  || fail "Gatekeeper refuses the app in the zip: $assessment"
[[ "$assessment" == *'source=Notarized Developer ID'* ]] \
  || fail "Gatekeeper accepts the app in the zip, but not as notarized: $assessment"
rm -rf "$check"

echo "Released $zip"
echo "  $name $version ($count), $note"
echo "  SHA-256 $(shasum -a 256 "$zip" | cut -d' ' -f1)"
