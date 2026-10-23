#!/bin/bash
# Builds "LD Manager.app" with the ldm CLI bundled in Contents/Helpers.
#
#   scripts/build-app.sh                 ad-hoc signed, for local use
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#                                        signed with hardened runtime, ready to notarize
#
# Output: build/LD Manager.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/build"
APP="$OUT/LD Manager.app"
IDENTITY="${SIGN_IDENTITY:--}"

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }

echo "▸ Generating Xcode project"
(cd App && xcodegen generate --quiet)

echo "▸ Building ldm"
swift build -c release --product ldm
LDM="$(swift build -c release --show-bin-path)/ldm"

echo "▸ Building app"
xcodebuild -project App/LDManager.xcodeproj -scheme LDManager -configuration Release \
  -derivedDataPath "$OUT/DerivedData" CODE_SIGN_IDENTITY=- build -quiet

rm -rf "$APP"
cp -R "$OUT/DerivedData/Build/Products/Release/LD Manager.app" "$APP"
mkdir -p "$APP/Contents/Helpers"
cp "$LDM" "$APP/Contents/Helpers/ldm"

echo "▸ Signing ($IDENTITY)"
SIGN_FLAGS=(--force --options runtime --timestamp)
[ "$IDENTITY" = "-" ] && SIGN_FLAGS=(--force --options runtime)
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP/Contents/Helpers/ldm"
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "✓ $APP"
