# Demo environment

The screenshots and clips of LD Manager are made from an invented world on a throwaway macOS
virtual machine, never on a real Mac: a user **alice** on a Mac called **Studio**, with nine
made-up launch jobs (Example, Northwind, Acme, Globex and Initech are fictional vendors).

| File | What it does |
|---|---|
| `seed.sh` | Run with sudo **inside the VM**: writes the demo programs, plists and log history, quarantines one program, disables one job, loads the rest. `--reset` removes it all. Refuses to run unless the computer name is Studio. |
| `history.sh` | Run as alice inside the VM after `seed.sh`: three edits through `ldm`, so Recent Changes has backups. |
| `capture.sh` | Run on the host: opens LD Manager in the VM with demo launch flags and crops the VM viewer's window to the app window. No clicks or key presses. |
| `shots.sh` | Every still, dark and light. |
| `cli.command` | Opened in the VM's Terminal: real `ldm` output for the CLI still. |
| `caption.swift`, `clip.sh` | Caption pills and the 15-second hero clip (mp4 and GIF) from four captured states. |

Outputs go to `demo/out/` (git-ignored).

## Demo launch flags

`App/Sources/DemoHooks.swift` reads these launch arguments; without them the app is unchanged.

```text
-demoAppearance light|dark
-demoSidebar user|allUsers|system|apple|problems|recent
-demoSelect <label>
-demoInspector NO
-demoEdit <label> [-demoEditProgram <path>] [-demoEditEvery <minutes>] [-demoEditMode Form|Keys|XML]
-demoWindow <width>x<height>     centred; the frame is written to /tmp/ldm-demo-frame
```

## Running it

1. A macOS 26 VM (we use lume) whose computer name is Studio, with a user alice logged in, the
   menu bar set to hide (`defaults write -g _HIHideMenuBar -bool true`) and the native viewer
   open on the host. Share `demo/out/share` into it and put the app and these scripts there.
2. In the VM: install `LD Manager.app` to /Applications, then `sudo seed.sh` and, as alice,
   `history.sh`. Wait about ten minutes so `dev.alice.devserver` passes 100 restarts.
3. On the host: `demo/shots.sh`.
4. The fix sequence for the clip: `capture.sh fix-1-edit -demoSidebar problems -demoSelect
   com.example.report -demoEdit com.example.report -demoEditProgram /Users/alice/bin/report.sh`,
   then in the VM `ldm edit report --program /Users/alice/bin/report.sh && ldm start report`,
   then `capture.sh fix-2-done -demoSidebar user -demoSelect com.example.report`, and
   `demo/clip.sh`.

macOS shows an "App Background Activity" notification when the demo jobs load. Clear it
before capturing (delete the records in alice's
`~/Library/Group Containers/group.com.apple.usernoted/db2/db` and restart NotificationCenter).
