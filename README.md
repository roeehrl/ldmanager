# LD Manager

A native macOS app and command-line tool for seeing, diagnosing and managing
**launchd** jobs: your LaunchAgents, agents for all users, and system LaunchDaemons.

It answers the question every launchd user eventually asks — *why isn't my job
running?* — in plain language, and never loses a key when it edits a plist.

- **One view of every layer.** For each job: the plist on disk, whether launchd has
  it loaded, its persistent enable/disable override, its PID, launch count and last
  exit code, joined into a single status (running, waiting, failed, disabled, not
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
- **`ldm`**, a CLI built on the same core, with `--json` output and documented exit codes.

Requires macOS 26 or later.

## Build

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
scripts/build-app.sh
```

This produces `build/LD Manager.app` with `ldm` bundled in `Contents/Helpers`. In the
app, **Settings → Command-line tool** links it into `/usr/local/bin`.

To sign for distribution, pass your Developer ID identity; the script signs with the
hardened runtime so the app can be notarized:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
```

The CLI also builds on its own:

```bash
swift build -c release --product ldm
```

Run the tests with `swift test`.

## The `ldm` command

```text
ldm list [--status failed|running|disabled|problems] [--scope user|allUsers|system] [--json|--plain]
ldm show <job> [--json]
ldm doctor [<job>] [--json]
ldm start|stop|restart|load|unload|enable|disable <job> [--dry-run]
ldm logs <job> [-n 40] [-f]
ldm new <name> (--every 15m | --cron "30 9 * * 1" | --keep-alive | --watch <path>) [--log <file>] -- <program> [args…]
ldm edit <job> [--program <path>] [--every …] [--log <file>] [--dry-run]
ldm remove <job> --confirm <label>
ldm explain <code>
```

A job can be named by its full label, its last label component, its file name, or
any unique part of its label. `--dry-run` prints the exact `launchctl` commands
instead of running them. Colors are off when output isn't a terminal or `NO_COLOR`
is set.

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

Changes go through `launchctl bootstrap`, `bootout`, `enable`, `disable`,
`kickstart` and `kill`. Changes to system daemons, and writes to `/Library`, ask for
an administrator password through macOS.

## Layout

```text
Sources/LDCore   job model, plist reading and lossless editing, launchctl adapter,
                 schedules, exit codes, the Doctor
Sources/ldm      the CLI (Swift Argument Parser)
App/             the SwiftUI app (XcodeGen project.yml, Sources, Resources)
Tests/           unit tests for the parsers, schedules, editing and the Doctor
scripts/         app bundle build script and icon renderer
docs/            research notes behind the design
```

## Not yet done

- A privileged helper (`SMAppService` daemon) so system-daemon changes don't ask for a
  password each time.
- Reading **Login Items & Extensions → Allow in the Background** state (Background
  Task Management), the second switch that can stop a job.
- Notifications when something adds or changes a launch job, and a timeline of
  upcoming runs.

## License

MIT — see [LICENSE](LICENSE).
