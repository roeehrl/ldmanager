#!/bin/bash
# Gives Recent Changes some history: three edits through ldm, each of which keeps a backup.
# Run as the demo user after seed.sh.
set -euo pipefail
LDM=${LDM:-"/Applications/LD Manager.app/Contents/Helpers/ldm"}
"$LDM" edit photos-import --log "$HOME/Library/Logs/photos-import.log"
sleep 2
"$LDM" edit backup --every 2h
sleep 2
"$LDM" edit backup --every 1h
