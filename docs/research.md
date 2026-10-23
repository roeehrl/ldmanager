# Research: a modern launchd manager for macOS

Collected 2026-10-23. **[unverified]** marks claims that still need checking on a real system.

## Competitors

| Tool | Model | Strengths | Weaknesses |
|---|---|---|---|
| LaunchControl (soma-zone) | ~$33, closed, notarized | Most complete: job analysis + QuickFix, Standard/Expert/XML editors, log viewer, QuickLaunch menu bar, cron conversion, templates, FDA isolation (`fdautil`) | Jargon-heavy, steep learning curve; breaks on OS releases (macOS 27 BTM crash, fdautil move, log UTF-8 crashes) |
| Lingon Pro (Peter Borg) | $23.99, closed, outside App Store | Plain-language task form, Timeline of upcoming runs, groups/tags/smart folders, change notifications | Assumes launchd knowledge, opaque tooltips, frequent paid upgrades |
| KnockKnock / BlockBlock (Objective-See) | Free, open | Signing provenance, VirusTotal, real-time persistence alerts, hides Apple items | List/alert only, not a manager |
| LaunchManager (Sean10000) | MIT, SwiftUI | Expandable rows with logs, form + XML editor, create job from a listening port | Not notarized |
| Launchd Manager, launchd-ui | Indie | Simple | Reported to silently drop unsupported keys on save |

Sources: soma-zone.com/LaunchControl (+ comparison, release notes), peterborgapps.com/lingon, objective-see.org, github.com/Sean10000/LaunchManager, launchd.info, sspai.com/post/110536.

## launchd facts the app must handle

- **Locations:** `~/Library/LaunchAgents` (user), `/Library/LaunchAgents` (every user), `/Library/LaunchDaemons` (root), `/System/Library/Launch{Agents,Daemons}` (sealed, read-only), `/System/Library/LaunchAngels` (Tahoe+, Apple only), app bundles' `Contents/Library/Launch{Agents,Daemons}` (SMAppService). Plists 0644, dirs 0755, correct owner, or launchd rejects them.
- **Domains:** `gui/<uid>` (user agents), `user/<uid>`, `system`. Service target = `domain/label`.
- **Verbs:** `bootstrap`/`bootout` (load/unload; `load`/`unload` legacy), `enable`/`disable` (persistent override; a disabled job cannot be bootstrapped), `print-disabled`, `kickstart [-k] [-p]`, `kill`, `print` (richest state, but "not an API": parse defensively, version-gate), `blame`, `list` (PID / last status / label; negative status = signal).
- **Disabled overrides store:** `/private/var/db/com.apple.xpc.launchd/disabled.<uid>.plist` **[unverified]**, root-only; always change via launchctl.
- **State from code:** no public API. Shell out to `launchctl print` / `print-disabled` / `list`, parse plists with `PropertyListSerialization`, watch job folders with FSEvents, poll.
- **Exit codes:** 0 ok; positive program-defined; negative = signal. Explain 78 EX_CONFIG, 126/127 not executable / not found, −9 SIGKILL, −15 SIGTERM, "exec failed: N" as errno.
- **Key behavior:** StartInterval and StartCalendarInterval coalesce runs missed during sleep; KeepAlive bool or dict (SuccessfulExit, Crashed, NetworkState, PathState, OtherJobEnabled); WatchPaths not recursive; QueueDirectories must be emptied; ExitTimeOut 20 s; ThrottleInterval 10 s **[unverified]**; launchd is not a shell (`~`, pipes need `sh -c`).
- **Background Task Management (BTM):** `/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm`; `sudo sfltool dumpbtm` shows disposition, developer, Team ID, owning bundle. "Allow in the Background" toggles are a **second disable layer**, separate from launchd overrides. `AssociatedBundleIdentifiers` sets the name/icon shown in Settings.
- **SMAppService** (13+): `.agent(plistName:)`, `.daemon(plistName:)`, statuses notRegistered / enabled / requiresApproval / notFound. SMJobBless deprecated.
- **Privilege:** ship an `SMAppService.daemon` helper over NSXPC with a narrow command set (write plist into `/Library/LaunchDaemons` root:wheel 0644; bootstrap/bootout/kickstart/enable/disable in `system`; read root-only logs; `sfltool dumpbtm`). Validate the client's code signature.
- **Distribution:** Developer ID + Hardened Runtime + notarization, no sandbox (App Store sandbox cannot drive launchctl). macOS 27: quarantined executables may not run as jobs **[unverified scope]**.
- **Logs:** tail `StandardOutPath`/`StandardErrorPath`; otherwise unified log (`log show/stream --predicate`). Decode invalid UTF-8 leniently.

## macOS UX guidance

- Three panes: `NavigationSplitView` sidebar (sources + smart filters) → `Table` (sortable) → `.inspector()`.
- macOS 26+ Liquid Glass: floating glass sidebar, grouped toolbar items on glass, monochrome toolbar icons (tint only for meaning), scroll edge effect instead of bar backgrounds, search top-trailing, `controlSize(.small)` for dense tables.
- Search tokens (`status:failed`, `domain:system`, `key:WatchPaths`), Settings scene, `MenuBarExtra`, full menu commands with shortcuts, type-to-select.
- Status = SF Symbol shape **and** color, with `.help()` tooltips. Destructive actions via `confirmationDialog`; move to Trash; undo.
- Emulate: Activity Monitor / Console (table + live inspector), Xcode inspector, Lingon Timeline, Objective-See provenance.

## CLI guidance (clig.dev)

- Consistent verbs; flags over positionals; `--json` (stable) and `--plain`; human output unstable.
- stdout data / stderr errors; `NO_COLOR`, non-TTY, `--no-color`; prompts only on TTY, `--no-input`, `--dry-run` prints exact launchctl commands.
- Distinct exit codes (1 general, 2 usage, 3 not found, 4 needs authorization, 5 launchd rejected, 6 doctor found problems).
- Examples-first help, typo suggestions, translate launchctl errors to plain language.
- Swift ArgumentParser; core logic in a shared Swift package used by app and CLI.

## Differentiators to build

1. Lossless editing: never drop unknown keys, diff before save, backup every write.
2. One truth view per job: file + live launchd state + override + BTM + signing, with disagreements flagged.
3. Doctor: plist validity, ownership/permissions, label ≠ filename, missing/non-executable/quarantined program, no trigger, disabled override, BTM-blocked, wrong domain, `~`/shell syntax without `sh -c`, respawn loop, uncleared QueueDirectories, missing FDA.
4. Exit-code and signal explainer.
5. Human-readable schedules + next-runs timeline.
6. Integrated log tail (files + unified log).
7. Safe privilege model with a notarized helper.
8. Background Items explorer with owner app, Team ID, orphans.
9. Change notifications + per-job history and restore.
10. First-class CLI (`ldm`), Shortcuts actions, menu bar extra, templates.
