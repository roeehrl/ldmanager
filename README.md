# LD Manager

[![CI](https://github.com/roeehrl/ldmanager/actions/workflows/ci.yml/badge.svg)](https://github.com/roeehrl/ldmanager/actions/workflows/ci.yml)

A native macOS app and command-line tool for seeing, diagnosing and managing
**launchd** jobs: your LaunchAgents, agents for all users, and system LaunchDaemons.

It answers the question every launchd user eventually asks — *why isn't my job
running?* — in plain language, and never loses a key when it edits a plist.

- **One view of every layer.** For each job: the plist on disk, whether launchd has
  it loaded, its persistent enable/disable override, its PID, launch count and last
  exit code, and its **App Background Activity** switch in Login Items — joined into
  a single status (running, waiting, failed, disabled, off in Login Items, not
  loaded, invalid).
- **The Doctor.** Checks every job for invalid plists, missing Labels, missing or
  non-executable programs, quarantined programs, unexpanded `~`, wrong ownership or
  permissions, missing log folders, restart loops, jobs that are enabled but not
  loaded, and failed runs — then offers a fix for each.
- **Readable schedules.** `StartCalendarInterval {Weekday 1, Hour 9, Minute 30}` is
  shown as *Mondays at 09:30*, with the next run times.
- **Exit codes explained.** `78` → *EX_CONFIG: usually a missing or non-executable
  program*; `-15` → *killed by SIGTERM*.
- **Lossless editing.** A plain-language form, a Keys view and a raw XML editor.
  Changes are applied to the file's own dictionary, so keys the form doesn't know
  about survive. Every save shows a diff first and keeps a backup you can restore
  from *Recent Changes*.
- **Menu bar extra** with a problem count and on/off switches for pinned jobs.
- **Optional privileged helper.** Approve it once and system daemons, `/Library`
  plists and Login Items checks stop asking for your password.
- **`ldm`**, a CLI built on the same core, with `--json` output and documented exit codes.

Requires macOS 26 or later.

## Build

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
scripts/build-app.sh
```

This produces `build/LD Manager.app` with `ldm` bundled in `Contents/Helpers`. In the
app, **Settings → Command-line tool** links it into `/usr/local/bin`.

The script signs with your first *Developer ID Application* or *Apple Development*
certificate (hardened runtime, ready to notarize), or with `SIGN_IDENTITY` if set.
`SIGN_IDENTITY=-` signs ad-hoc; everything works except the privileged helper.

The CLI also builds on its own:

```bash
swift build -c release --product ldm
```

Run the tests with `swift test`.

## The `ldm` command

```text
ldm list [--status failed|running|disabled|problems] [--scope user|allUsers|system] [--json|--plain]
ldm show <job> [--json] [--background]
ldm doctor [<job>] [--json] [--background]
ldm start|stop|restart|load|unload|enable|disable <job> [--dry-run]
ldm logs <job> [-n 40] [-f]
ldm new <name> (--every 15m | --cron "30 9 * * 1" | --keep-alive | --watch <path>) [--log <file>] -- <program> [args…]
ldm edit <job> [--program <path>] [--every …] [--log <file>] [--dry-run]
ldm remove <job> --confirm <label>
ldm explain <code>
ldm helper
```

A job can be named by its full label, its last label component, its file name, or
any unique part of its label. `--dry-run` prints the exact `launchctl` commands
instead of running them. Colors are off when output isn't a terminal or `NO_COLOR`
is set.

`--background` re-reads Login Items › App Background Activity. macOS asks for your
password each time, so without the flag `ldm` uses the last result it read.

| Exit code | Meaning |
|---|---|
| 0 | Success |
| 1 | General error |
| 2 | Usage error, or the name matches several jobs |
| 3 | No such job |
| 4 | Administrator authorization needed or cancelled |
| 5 | launchd rejected the operation |
| 6 | `doctor` found problems |

## How it works

There is no public API for launchd state, so LD Manager reads it the way an
administrator would: `launchctl print <domain>` for each domain's services,
`launchctl print-disabled` for overrides, `launchctl print <domain>/<label>` for a
job's details, and the plist files themselves. Apple documents `launchctl print`'s
output as not being an API, so every parser ignores lines it doesn't recognise.

The **App Background Activity** switches (called *Allow in the Background* on earlier macOS versions) live in Background Task Management, a
database only root can read. There is no public API for it, so LD Manager reads it
with `sfltool dumpbtm`, which shows an administrator prompt every time it runs.
Without the helper it is only read when you ask (**Check Login Items…** in the
app, `--background` in the CLI); with the helper it is read silently, and the app
keeps it fresh. The result is cached in `~/Library/Caches/LDManager`. These switches can't be changed programmatically;
the app opens the Login Items pane in System Settings instead.

## The privileged helper

Changing system daemons and files in `/Library` needs root. Without help, every
such action shows macOS's administrator prompt. LD Manager can instead install a
small helper (`SMAppService` daemon, bundled in the app) that you approve once in
**System Settings › General › Login Items › App Background Activity**.

- Nothing is asked at launch. The first time you do something that needs root, LD
  Manager explains the helper and offers **Continue**, **Use Password Instead** or
  **Cancel**. Choosing passwords is remembered; a banner, not a dialog, reminds you.
- On **Continue**, System Settings opens with a small guide beside it. LD Manager
  detects the approval on its own, confirms the helper answers, and finishes what
  you were doing.
- The helper only accepts LD Manager and its bundled `ldm`, verified by code
  signature (same team, specific bundle identifiers). It does a fixed set of things,
  each validated: `launchctl` on the `system` domain, writing or removing plists in
  `/Library/LaunchDaemons` and `/Library/LaunchAgents`, fixing their permissions,
  creating log folders, removing quarantine, and reading Login Items.
- Remove it any time in **Settings › Privileged helper**. `ldm helper` reports
  whether it is reachable. It exits when idle and launchd relaunches it from the
  current app, so updates take effect on their own (`ldm helper --restart` forces it).

Changes go through `launchctl bootstrap`, `bootout`, `enable`, `disable`,
`kickstart` and `kill`. Changes to system daemons, and writes to `/Library`, ask for
an administrator password through macOS.

## Layout

```text
Sources/LDCore   job model, plist reading and lossless editing, launchctl adapter,
                 schedules, exit codes, the Doctor
Sources/ldm      the CLI (Swift Argument Parser)
Sources/LDManagerHelper  the privileged helper (XPC, runs as root)
App/             the SwiftUI app (XcodeGen project.yml, Sources, Resources)
Tests/           unit tests for the parsers, schedules, editing and the Doctor
scripts/         app bundle build script and icon renderer
docs/            research notes behind the design
```

## Not yet done

- Notifications when something adds or changes a launch job, and a timeline of
  upcoming runs.

## License

MIT — see [LICENSE](LICENSE).
