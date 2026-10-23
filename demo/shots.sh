#!/bin/bash
# Every still in docs/assets and on the site, in one go, from the demo VM (see demo/README.md).
#   demo/shots.sh            dark and light
#   LOOKS=dark demo/shots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export GUEST_W=${GUEST_W:-1280} SIZE=${SIZE:-1240x760} MARGIN=${MARGIN:-20}
LOOKS=${LOOKS:-"dark light"}

for look in $LOOKS; do
  export APPEARANCE=$look
  demo/capture.sh "hero-$look"    -demoSidebar user -demoSelect com.example.report
  demo/capture.sh "doctor-$look"  -demoSidebar problems -demoSelect com.example.report
  demo/capture.sh "editor-$look"  -demoSidebar user -demoSelect com.example.backup \
                                  -demoEdit com.example.backup -demoEditEvery 30
  demo/capture.sh "xml-$look"     -demoSidebar user -demoSelect com.example.backup \
                                  -demoEdit com.example.backup -demoEditEvery 30 -demoEditMode XML
  demo/capture.sh "recent-$look"  -demoSidebar recent
  demo/capture.sh "daemons-$look" -demoSidebar system -demoSelect com.example.diskwatch
done
