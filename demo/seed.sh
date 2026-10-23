#!/bin/bash
# Seeds the demo world on a throwaway macOS machine (the seo-demo VM): a user "alice" with
# invented launch jobs in every state LD Manager shows. Never run this on a real Mac.
#
#   sudo demo/seed.sh            # as an admin, on the demo machine
#   sudo demo/seed.sh --reset    # remove everything it created first
#
# Everything here is made up: vendors (Example, Northwind, Acme, Globex, Initech), programs
# (tiny shell scripts) and log lines.
set -euo pipefail

DEMO_USER=${DEMO_USER:-alice}
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
id "$DEMO_USER" >/dev/null 2>&1 || { echo "no user $DEMO_USER" >&2; exit 1; }
[ "$(scutil --get ComputerName 2>/dev/null)" = "Studio" ] || [ "${FORCE:-}" = 1 ] || {
  echo "This doesn't look like the demo machine (ComputerName != Studio). Set FORCE=1 to override." >&2; exit 1; }

U=$(id -u "$DEMO_USER")
H=$(dscl . -read "/Users/$DEMO_USER" NFSHomeDirectory | awk '{print $2}')
AGENTS="$H/Library/LaunchAgents"
LOGS="$H/Library/Logs"
as_user() { launchctl asuser "$U" sudo -u "$DEMO_USER" "$@"; }

USER_JOBS=(com.example.backup dev.alice.notes-sync org.acme.photos-import com.example.report
           com.globex.updater dev.alice.devserver com.initech.helper)
ALL_USERS_JOBS=(io.northwind.agent)
DAEMONS=(com.example.diskwatch)

reset() {
  for l in "${USER_JOBS[@]}" "${ALL_USERS_JOBS[@]}"; do
    launchctl bootout "gui/$U/$l" 2>/dev/null || true
    launchctl enable "gui/$U/$l" 2>/dev/null || true
  done
  for l in "${DAEMONS[@]}"; do launchctl bootout "system/$l" 2>/dev/null || true; done
  for l in "${USER_JOBS[@]}"; do rm -f "$AGENTS/$l.plist"; done
  for l in "${ALL_USERS_JOBS[@]}"; do rm -f "/Library/LaunchAgents/$l.plist"; done
  for l in "${DAEMONS[@]}"; do rm -f "/Library/LaunchDaemons/$l.plist"; done
  rm -rf "$H/bin" "$H/Pictures/Import" "$H/Library/Application Support/Globex" \
         "$H/Library/Application Support/LDManager" "$LOGS/Backup" "$LOGS/photos-import.log" \
         "$LOGS/notes-sync.log" "$LOGS/devserver.log" "$LOGS/report.log" \
         /usr/local/libexec/northwind-agent /usr/local/libexec/diskwatch /var/log/diskwatch.log
}

[ "${1:-}" = "--reset" ] && { reset; echo "reset"; }
reset

# --- Programs -------------------------------------------------------------------------
mkdir -p "$H/bin" "$AGENTS" "$LOGS/Backup" "$H/Pictures/Import" /usr/local/libexec

cat > "$H/bin/backup.sh" <<'EOF'
#!/bin/sh
echo "$(date '+%Y-%m-%d %H:%M:%S') backup: snapshot of ~/Documents started"
echo "$(date '+%Y-%m-%d %H:%M:%S') backup: 1,284 files checked, 37 changed, 212 MB copied"
echo "$(date '+%Y-%m-%d %H:%M:%S') backup: done in 41 s"
EOF
cat > "$H/bin/notes-sync" <<'EOF'
#!/bin/sh
while true; do echo "$(date '+%Y-%m-%d %H:%M:%S') notes-sync: up to date (412 notes)"; sleep 300; done
EOF
cat > "$H/bin/photos-import.sh" <<'EOF'
#!/bin/sh
n=$(ls "$HOME/Pictures/Import" 2>/dev/null | wc -l | tr -d ' ')
echo "$(date '+%Y-%m-%d %H:%M:%S') photos-import: $n new photos imported into Library"
EOF
# The fix target for the failing report job: it lives in ~/bin, but the plist points elsewhere.
cat > "$H/bin/report.sh" <<'EOF'
#!/bin/sh
echo "$(date '+%Y-%m-%d %H:%M:%S') report: weekly summary written to ~/Documents/Reports"
EOF
cat > "$H/bin/devserver" <<'EOF'
#!/bin/sh
echo "$(date '+%Y-%m-%d %H:%M:%S') devserver: error: port 8080 already in use" >&2
exit 1
EOF
mkdir -p "$H/Library/Application Support/Globex"
cat > "$H/Library/Application Support/Globex/updater" <<'EOF'
#!/bin/sh
echo "Globex Updater: no updates available"
EOF
cat > /usr/local/libexec/northwind-agent <<'EOF'
#!/bin/sh
while true; do echo "$(date '+%Y-%m-%d %H:%M:%S') Northwind Sync: watching 3 folders"; sleep 600; done
EOF
cat > /usr/local/libexec/diskwatch <<'EOF'
#!/bin/sh
echo "$(date '+%Y-%m-%d %H:%M:%S') diskwatch: Macintosh HD 61% used, SMART verified"
EOF
chmod 755 "$H/bin/"* "$H/Library/Application Support/Globex/updater" /usr/local/libexec/northwind-agent /usr/local/libexec/diskwatch
chown "$DEMO_USER":staff "$AGENTS"
chown -R "$DEMO_USER":staff "$H/bin" "$H/Pictures/Import" "$H/Library/Application Support/Globex" "$LOGS/Backup"
for i in 1 2 3 4 5 6; do touch "$H/Pictures/Import/IMG_04$((10 + i)).HEIC"; done
chown "$DEMO_USER":staff "$H/Pictures/Import/"*
# Downloaded from the web, never opened: macOS quarantines it, and launchd won't run it.
xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$H/Library/Application Support/Globex/updater"

# Invented log history so the inspector's log tail has content.
{
  for d in 3 2 1; do
    t=$(date -v-"${d}"H '+%Y-%m-%d %H:%M:%S')
    echo "$t backup: snapshot of ~/Documents started"
    echo "$t backup: 1,2$((70 + d)) files checked, $((20 + d * 5)) changed, $((150 + d * 20)) MB copied"
    echo "$t backup: done in $((38 + d)) s"
  done
} > "$LOGS/Backup/backup.log"
chown "$DEMO_USER":staff "$LOGS/Backup/backup.log"

# --- Plists ---------------------------------------------------------------------------
plist() { # path, body
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$2
</dict>
</plist>
EOF
}

plist "$AGENTS/com.example.backup.plist" "
  <key>Label</key><string>com.example.backup</string>
  <key>ProgramArguments</key><array><string>$H/bin/backup.sh</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOGS/Backup/backup.log</string>
  <key>StandardErrorPath</key><string>$LOGS/Backup/backup.log</string>"

plist "$AGENTS/dev.alice.notes-sync.plist" "
  <key>Label</key><string>dev.alice.notes-sync</string>
  <key>ProgramArguments</key><array><string>$H/bin/notes-sync</string></array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOGS/notes-sync.log</string>"

plist "$AGENTS/org.acme.photos-import.plist" "
  <key>Label</key><string>org.acme.photos-import</string>
  <key>ProgramArguments</key><array><string>$H/bin/photos-import.sh</string></array>
  <key>WatchPaths</key><array><string>$H/Pictures/Import</string></array>
  <key>StandardOutPath</key><string>$LOGS/photos-import.log</string>"

# Points at a program that isn't there: launchd exits it with 78 (EX_CONFIG).
plist "$AGENTS/com.example.report.plist" "
  <key>Label</key><string>com.example.report</string>
  <key>ProgramArguments</key><array><string>/usr/local/bin/report.sh</string><string>--weekly</string></array>
  <key>StartCalendarInterval</key><dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>$LOGS/report.log</string>"

plist "$AGENTS/com.globex.updater.plist" "
  <key>Label</key><string>com.globex.updater</string>
  <key>ProgramArguments</key><array><string>$H/Library/Application Support/Globex/updater</string></array>
  <key>StartInterval</key><integer>86400</integer>"

# Crashes straight away and KeepAlive restarts it: a restart loop.
plist "$AGENTS/dev.alice.devserver.plist" "
  <key>Label</key><string>dev.alice.devserver</string>
  <key>ProgramArguments</key><array><string>$H/bin/devserver</string><string>--port</string><string>8080</string></array>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>1</integer>
  <key>WorkingDirectory</key><string>$H</string>
  <key>StandardErrorPath</key><string>$LOGS/devserver.log</string>"

plist "$AGENTS/com.initech.helper.plist" "
  <key>Label</key><string>com.initech.helper</string>
  <key>ProgramArguments</key><array><string>$H/bin/backup.sh</string></array>
  <key>StartInterval</key><integer>1800</integer>"

plist /Library/LaunchAgents/io.northwind.agent.plist "
  <key>Label</key><string>io.northwind.agent</string>
  <key>ProgramArguments</key><array><string>/usr/local/libexec/northwind-agent</string></array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>"

plist /Library/LaunchDaemons/com.example.diskwatch.plist "
  <key>Label</key><string>com.example.diskwatch</string>
  <key>ProgramArguments</key><array><string>/usr/local/libexec/diskwatch</string></array>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/var/log/diskwatch.log</string>"

chown "$DEMO_USER":staff "$AGENTS"/*.plist; chmod 644 "$AGENTS"/*.plist
chown root:wheel /Library/LaunchAgents/io.northwind.agent.plist /Library/LaunchDaemons/com.example.diskwatch.plist
chmod 644 /Library/LaunchAgents/io.northwind.agent.plist /Library/LaunchDaemons/com.example.diskwatch.plist

# --- Load -----------------------------------------------------------------------------
for l in com.example.backup dev.alice.notes-sync org.acme.photos-import com.example.report \
         com.globex.updater dev.alice.devserver; do
  launchctl bootstrap "gui/$U" "$AGENTS/$l.plist" || echo "warn: $l didn't load"
done
launchctl bootstrap "gui/$U" /Library/LaunchAgents/io.northwind.agent.plist || true
launchctl bootstrap system /Library/LaunchDaemons/com.example.diskwatch.plist || true
# Off: a persistent disable override, so launchd ignores it even at login.
launchctl disable "gui/$U/com.initech.helper"

# One run each, so they have a last exit code: report fails with 78, globex is blocked.
launchctl kickstart "gui/$U/com.example.report" || true
launchctl kickstart "gui/$U/com.globex.updater" || true
touch "$H/Pictures/Import/IMG_0417.HEIC"; chown "$DEMO_USER":staff "$H/Pictures/Import/IMG_0417.HEIC"

echo "seeded. Wait ~3 min for devserver's restart count to pass 100, then run demo/history.sh as $DEMO_USER."
