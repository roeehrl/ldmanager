# Contributing to LD Manager

Thanks for helping. Bug reports, fixes, new Doctor checks, better explanations and
translations are all welcome.

## 60-second setup

You need macOS 26, Xcode 26 and XcodeGen (`brew install xcodegen`).

```bash
git clone https://github.com/roeehrl/ldmanager && cd ldmanager
swift test                                  # core and CLI tests, no Xcode project needed
swift run ldm list                          # the CLI against your own Mac, read-only
scripts/build-app.sh                        # the app, in build/LD Manager.app
```

Most logic lives in `Sources/LDCore` and is shared by the app (`App/`) and the CLI
(`Sources/ldm`), so a change there shows up in both and can be unit-tested without the UI.

## Testing without touching your own jobs

Reading is safe. For anything that writes, use the throwaway job pattern from the tests
(`com.example.*` labels) or the demo world in [`demo/`](demo/README.md), which seeds nine
invented jobs on a disposable macOS VM. Never commit real labels, paths, hostnames or
usernames from your Mac in tests, fixtures or screenshots.

## Where things are

| You want to… | Look in |
|---|---|
| add or improve a Doctor check | `Sources/LDCore/Doctor.swift` (+ a test in `Tests/LDCoreTests`) |
| explain another exit code or signal | `Sources/LDCore/ExitCode.swift` |
| parse more of `launchctl print` | `Sources/LDCore/Launchctl.swift` (parse defensively: it is not an API) |
| describe schedules better | `Sources/LDCore/Schedule.swift` |
| change the CLI | `Sources/ldm/` (keep `--json` output stable; add fields, don't rename) |
| change the app | `App/Sources/` (SwiftUI; regenerate the project with `xcodegen` in `App/`) |

## Pull requests

- One change per PR, with a short description of what a user sees differently.
- `swift test` passes; new logic comes with a test.
- UI changes: a before/after screenshot made with demo data.
- Plist edits must stay lossless: never drop keys you don't understand.
- Match the surrounding code style; no new dependencies without discussing them first.

## Reporting bugs

Use the bug form. The most useful attachment is `ldm show <job> --json` (check it for
anything private first) and, for parsing bugs, the relevant lines of
`launchctl print gui/$(id -u)/<label>`.

Security problems: please follow [SECURITY.md](SECURITY.md) instead of opening an issue.

By contributing you agree that your contributions are licensed under the MIT licence and
that you follow the [Code of Conduct](CODE_OF_CONDUCT.md).
