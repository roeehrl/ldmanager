#!/bin/bash
# Builds a signed, notarized and stapled release of LD Manager:
#
#   build/release/LD-Manager.dmg     the app and an Applications link in a styled window
#   build/release/ldm-macos.zip      the ldm command on its own
#   build/release/SHA256SUMS.txt
#   build/release/appcast.xml        the signed Sparkle update feed (publish with scripts/publish-appcast.sh)
#
# Needs dmgbuild (pip install dmgbuild), a "Developer ID Application" certificate in your
# keychain, and notarization credentials, either an App Store Connect API key:
#
#   ASC_KEY_ID=ABC123XYZ ASC_ISSUER=<issuer uuid> scripts/release.sh
#   (key file at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8)
#
# or a stored notarytool profile:
#
#   NOTARY_PROFILE=my-profile scripts/release.sh
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="build/release"
APP="build/LD Manager.app"
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' App/project.yml)

if [ -n "${ASC_KEY_ID:-}" ]; then
  : "${ASC_ISSUER:?Set ASC_ISSUER to the issuer ID of the API key}"
  KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
  [ -f "$KEY" ] || { echo "Missing $KEY" >&2; exit 1; }
  NOTARY=(--key "$KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER")
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY=(--keychain-profile "$NOTARY_PROFILE")
else
  echo "Set ASC_KEY_ID and ASC_ISSUER, or NOTARY_PROFILE (see the top of this script)." >&2
  exit 1
fi

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
fi
case "$SIGN_IDENTITY" in
  "Developer ID Application: "*) ;;
  *) echo "A Developer ID Application certificate is required for a release." >&2; exit 1 ;;
esac
export SIGN_IDENTITY

notarize() {
  echo "▸ Notarizing $(basename "$1")"
  local result
  result=$(xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --output-format json)
  local status id
  status=$(printf '%s' "$result" | plutil -extract status raw -o - - 2>/dev/null || echo unknown)
  id=$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || echo "")
  if [ "$status" != "Accepted" ]; then
    echo "Notarization $status for $1" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "${NOTARY[@]}" >&2
    exit 1
  fi
}

echo "▸ LD Manager $VERSION"
scripts/build-app.sh

rm -rf "$OUT"
mkdir -p "$OUT"

# 1. The app: notarize a zip of it, then staple the ticket to the app itself.
ditto -c -k --keepParent "$APP" "$OUT/app-notarize.zip"
notarize "$OUT/app-notarize.zip"
rm "$OUT/app-notarize.zip"
xcrun stapler staple "$APP"

# 2. The disk image: the stapled app and a link to Applications in a styled window
#    (background from packaging/dmg/DMGBackground.swift, layout in packaging/dmg/settings.py),
#    written by dmgbuild without scripting Finder.
echo "▸ Building the disk image"
DMGBUILD="${DMGBUILD:-$(command -v dmgbuild || echo "$HOME/tools/dmgbuild-venv/bin/dmgbuild")}"
[ -x "$DMGBUILD" ] || { echo "dmgbuild not found: python3 -m venv ~/tools/dmgbuild-venv && ~/tools/dmgbuild-venv/bin/pip install dmgbuild" >&2; exit 1; }
mkdir -p build/dmg
swiftc -O packaging/dmg/DMGBackground.swift -o build/DMGBackground
build/DMGBackground build/dmg >/dev/null
"$DMGBUILD" -s packaging/dmg/settings.py -D app="$APP" -D background=build/dmg/background.png \
  "LD Manager" "$OUT/LD-Manager.dmg"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT/LD-Manager.dmg"
notarize "$OUT/LD-Manager.dmg"
xcrun stapler staple "$OUT/LD-Manager.dmg"

# 3. ldm on its own. A bare binary can't carry a stapled ticket; Gatekeeper checks online.
echo "▸ Packaging ldm"
CLI=$(mktemp -d)
ditto "$APP/Contents/Helpers/ldm" "$CLI/ldm"
ditto -c -k "$CLI" "$OUT/ldm-macos.zip"
rm -rf "$CLI"
notarize "$OUT/ldm-macos.zip"

(cd "$OUT" && shasum -a 256 LD-Manager.dmg ldm-macos.zip > SHA256SUMS.txt)

# 4. The update feed for Sparkle: one item, this DMG, signed with the EdDSA key in the
#    login keychain (account "ldmanager"). Published by scripts/publish-appcast.sh once
#    the GitHub release exists. See docs/auto-update.md.
echo "▸ Building the update feed"
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
diff <(codesign -d -r- "$APP/Contents/MacOS/LDManagerHelper" 2>&1 | sed -n 's/^designated => //p') scripts/helper-requirement.txt \
  || { echo "The helper's code signing requirement changed; approved helpers would stop launching." >&2; exit 1; }
NOTES="release-notes/$VERSION.md"
[ -f "$NOTES" ] || { echo "Missing $NOTES (Markdown shown in the update window)" >&2; exit 1; }
SPARKLE_BIN="${SPARKLE_BIN:-build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}"
[ -x "$SPARKLE_BIN/generate_appcast" ] || { echo "Sparkle tools not found in $SPARKLE_BIN" >&2; exit 1; }
STAGE="$OUT/sparkle"
mkdir -p "$STAGE"
cp "$OUT/LD-Manager.dmg" "$STAGE/"
cp "$NOTES" "$STAGE/LD-Manager.md"
"$SPARKLE_BIN/generate_appcast" --account ldmanager \
  --download-url-prefix "https://github.com/roeehrl/ldmanager/releases/download/v$VERSION/" \
  --link "https://github.com/roeehrl/ldmanager" \
  --full-release-notes-url "https://github.com/roeehrl/ldmanager/releases/tag/v$VERSION" \
  --embed-release-notes --maximum-deltas 0 \
  -o "$OUT/appcast.xml" "$STAGE" >/dev/null
rm -rf "$STAGE"
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$OUT/appcast.xml" || { echo "appcast.xml doesn't name build $BUILD" >&2; exit 1; }
grep -q 'sparkle:edSignature=' "$OUT/appcast.xml" || { echo "appcast.xml enclosure isn't signed" >&2; exit 1; }

echo "▸ Verifying"
spctl -a -vv "$APP" 2>&1 | sed 's/^/  /'
spctl -a -vv -t open --context context:primary-signature "$OUT/LD-Manager.dmg" 2>&1 | sed 's/^/  /'
xcrun stapler validate "$APP" | sed 's/^/  /'
xcrun stapler validate "$OUT/LD-Manager.dmg" | sed 's/^/  /'

echo "✓ $OUT"
cat "$OUT/SHA256SUMS.txt"
echo "Next: gh release create v$VERSION $OUT/LD-Manager.dmg $OUT/ldm-macos.zip $OUT/SHA256SUMS.txt …, then scripts/publish-appcast.sh"
