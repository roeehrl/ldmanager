#!/bin/bash
# Builds "LD Manager.app" with the ldm CLI and the privileged helper bundled.
#
#   scripts/build-app.sh             signs with your first Developer ID Application
#                                    or Apple Development certificate, if you have one
#   SIGN_IDENTITY="…" scripts/build-app.sh
#                                    signs with that identity
#   SIGN_IDENTITY=- scripts/build-app.sh
#                                    ad-hoc signs (the helper won't run)
#
# Output: build/LD Manager.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/build"
APP="$OUT/LD Manager.app"
HELPER_LABEL="io.github.roeehrl.ldmanager.helper"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
  [ -z "$SIGN_IDENTITY" ] && SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }

echo "▸ Generating Xcode project"
(cd App && xcodegen generate --quiet)

echo "▸ Building ldm and the helper"
swift build -c release --product ldm
swift build -c release --product LDManagerHelper
BIN="$(swift build -c release --show-bin-path)"

echo "▸ Building app"
xcodebuild -project App/LDManager.xcodeproj -scheme LDManager -configuration Release \
  -derivedDataPath "$OUT/DerivedData" CODE_SIGN_IDENTITY=- build -quiet

rm -rf "$APP"
cp -R "$OUT/DerivedData/Build/Products/Release/LD Manager.app" "$APP"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/ldm" "$APP/Contents/Helpers/ldm"
cp "$BIN/LDManagerHelper" "$APP/Contents/MacOS/LDManagerHelper"
cp "App/Helper/$HELPER_LABEL.plist" "$APP/Contents/Library/LaunchDaemons/"

if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "▸ Signing ad-hoc — the privileged helper needs a real signing identity and won't run"
  FLAGS=(--force --options runtime)
else
  echo "▸ Signing with “$SIGN_IDENTITY”"
  FLAGS=(--force --options runtime --timestamp)
fi
# Sparkle's nested code, innermost first (Xcode signed it ad hoc). Never --deep.
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FW/Versions/B/XPCServices/Installer.xpc"
  codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FW/Versions/B/Autoupdate"
  codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FW/Versions/B/Updater.app"
  codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FW"
fi
for key in SUFeedURL SUPublicEDKey SURequireSignedFeed; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || { echo "Info.plist is missing $key" >&2; exit 1; }
done
codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" --identifier io.github.roeehrl.ldmanager.ldm "$APP/Contents/Helpers/ldm"
codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" --identifier "$HELPER_LABEL" "$APP/Contents/MacOS/LDManagerHelper"
codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

# Keep one copy: drop Xcode's intermediate app bundles and keep build/ out of
# Spotlight and Launch Services, so they don't appear as extra "LD Manager" apps.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for product in "$OUT"/DerivedData/Build/Products/*/"LD Manager.app"; do
  [ -d "$product" ] || continue
  "$LSREGISTER" -u "$product" 2>/dev/null || true
  rm -rf "$product"
done
touch "$OUT/.metadata_never_index"

echo "✓ $APP"
