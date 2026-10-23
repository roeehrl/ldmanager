#!/bin/bash
# Captures LD Manager stills from the demo VM, without touching the host's mouse or keyboard.
# The app is opened in the VM with demo launch flags (App/Sources/DemoHooks.swift); the VM's
# native viewer window is captured from the host and cropped to the app window.
#
#   demo/capture.sh <name> [demo flags…]
#   demo/capture.sh hero -demoSidebar user -demoSelect com.example.report
#   FRAME='100 80 900 560' demo/capture.sh cli    # any window already on screen
#
# Needs: the VM running with the native viewer (see demo/README.md), seed.sh done.
# Output: demo/out/shots/<name>.png (2x, window plus a margin of wallpaper).
set -euo pipefail
cd "$(dirname "$0")/.."

VM=${VM:-seo-demo-macos-ldmanager}
LUME=${LUME:-$HOME/.local/bin/lume}
SIZE=${SIZE:-1180x740}      # app window, points
MARGIN=${MARGIN:-40}        # wallpaper around it, points
GUEST_W=${GUEST_W:-1280}    # guest screen width, points
APPEARANCE=${APPEARANCE:-}  # dark | light (empty: leave as is)
WAIT=${WAIT:-5}
name=$1; shift
mkdir -p demo/out/shots

flags=""
for a in "$@"; do flags+=" $(printf %q "$a")"; done
[ -n "$APPEARANCE" ] && flags+=" -demoAppearance $APPEARANCE"

if [ -z "${FRAME:-}" ]; then
"$LUME" ssh "$VM" --storage external "U=\$(id -u alice)
  as() { echo lume | sudo -S launchctl asuser \$U sudo -u alice \"\$@\" 2>/dev/null; }
  echo lume | sudo -S pkill -x 'LD Manager' 2>/dev/null; echo lume | sudo -S pkill -x NotificationCenter 2>/dev/null; sleep 1; rm -f /tmp/ldm-demo-frame
  as open '/Applications/LD Manager.app' --args -demoWindow $SIZE$flags" >/dev/null 2>&1 || true
sleep "$WAIT"
frame=$("$LUME" ssh "$VM" --storage external 'cat /tmp/ldm-demo-frame' 2>/dev/null | grep -m1 '[0-9]')
else
frame=$FRAME   # crop this window (x y w h, points) instead of launching LD Manager
fi
read -r fx fy fw fh <<<"$frame"

wid=$(swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in l where (w["kCGWindowOwnerName"] as? String) == "Lume" && ((w["kCGWindowName"] as? String) ?? "").contains("'"$VM"'") { print(w["kCGWindowNumber"]!); break }' 2>/dev/null)
raw="$PWD/demo/out/shots/raw-$name.png"
screencapture -x -o -l "$wid" "$raw"

W=$(sips -g pixelWidth "$raw" | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$raw" | awk '/pixelHeight/{print $2}')
# The guest screen fills the bottom of the viewer window (16:10); the viewer's toolbar is above.
s=$(echo "$W / $GUEST_W" | bc -l)
top=$(echo "$H - $W / 1.6" | bc -l)
cx=$(printf %.0f "$(echo "($fx - $MARGIN) * $s" | bc -l)")
cy=$(printf %.0f "$(echo "$top + ($fy - $MARGIN) * $s" | bc -l)")
cw=$(printf %.0f "$(echo "($fw + 2 * $MARGIN) * $s" | bc -l)")
ch=$(printf %.0f "$(echo "($fh + 2 * $MARGIN) * $s" | bc -l)")
ow=$(( (fw + 2 * MARGIN) * 2 )); oh=$(( (fh + 2 * MARGIN) * 2 ))
ffmpeg -loglevel error -y -i "$raw" -vf "crop=$cw:$ch:$cx:$cy,scale=$ow:$oh:flags=lanczos" "demo/out/shots/$name.png"
echo "raw ${W}x${H}" >&2; rm -f "$raw"
echo "demo/out/shots/$name.png (${ow}x${oh})"
