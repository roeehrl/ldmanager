> **Implemented in 0.1.4.** Where the build differs from this research write-up, the code wins:
> - Release notes are Markdown (`release-notes/<version>.md`), rendered natively by Sparkle; no web view.
> - The update key lives in the login keychain under account `ldmanager` (`generate_appcast --account ldmanager`).
> - A helper from before 0.1.4 can't be asked to exit, so the app restarts it with `launchctl kickstart -k`
>   through the helper; newer helpers get `exitForUpdate`. Tested on this Mac: the helper switched builds
>   without re-registering or a new approval.
> - The menu bar's "ready" row installs the staged update directly (Sparkle ignores `checkForUpdates`
>   while an update waits for quit).
> - `scripts/publish-appcast.sh` publishes the feed to the `gh-pages` branch after checking the release asset.
> - End-to-end tests serve a signed feed from `http://127.0.0.1` (exempt from App Transport Security)
>   with `defaults write io.github.roeehrl.ldmanager LDMStagingFeedURL …`; `file://` feeds are refused.

# LD Manager auto-updater: design recommendation

Status: decision document, verified against primary sources on 2026-11-12. Repo files were read only; nothing was modified.

## 0. Decisions at a glance

| Topic | Decision |
|---|---|
| Framework | **Sparkle 2.10.1** via SwiftPM, pinned `exactVersion: 2.10.1`. Hard floor **2.9.6**, because of the Aug 2026 root LPE advisories. |
| Defaults | Checks ON, auto-download ON and auto-install ON, with no permission prompt. Checks run daily. Installs happen on quit, or at an idle moment with a silent relaunch. |
| Archive | The existing Developer ID-signed, notarized and stapled **`LD-Manager.dmg`**. No second artifact and no deltas. |
| Feed | `https://roeehrl.github.io/ldmanager/appcast.xml` (GitHub Pages, `gh-pages` branch). **Signed feed**, one item, rebuilt on each release. |
| Enclosure | `https://github.com/roeehrl/ldmanager/releases/download/vX.Y.Z/LD-Manager.dmg`, versioned and never `latest`. |
| Security keys | `SUVerifyUpdateBeforeExtraction=YES` and `SURequireSignedFeed=YES` from the first Sparkle build. This is free, since there are no legacy clients. |
| Versioning | `CURRENT_PROJECT_VERSION` is a strictly increasing integer. The first Sparkle build is **5** (0.1.4). |
| Helper | The helper reports its build. On a mismatch the app asks it to exit, so launchd starts the new `BundleProgram`. `unregister`/`register` is only a fallback. |
| CLI | No updater in `ldm` and no network access. It follows the bundle through the symlink. |
| Bootstrap | Users on 0.1.3 or earlier download 0.1.4 by hand once. |

---

## 1. Fact-check: conflicts I settled

1. **Sparkle version and security floor (confirmed).** The releases page lists 2.10.1 (25 Oct), 2.10.0 (13 Sep; macOS 12 minimum, CocoaPods dropped), 2.9.6 (17 Aug; privilege-escalation fix, hardened archive move), 2.9.5 (2 Aug; delta symlink fix), 2.9.2 (17 May; delta symlink and installer XPC validation fixes) and 2.9.0 (22 Feb; signed feeds, Markdown notes, `sparkle-cli` removed). https://github.com/sparkle-project/Sparkle/releases
   - The advisories page lists GHSA-3x7w-j75x-ppq5 and GHSA-4v99-qgq9-6pxp (High, 17 Aug 2026), GHSA-gmj2-gq3j-vqmj (2 Aug), and GHSA-hg88-v3cw-3qrh and GHSA-g3hp-f6mg-559v (19 May). https://github.com/sparkle-project/Sparkle/security/advisories
   - The page doesn't show patched versions. Matching publication dates to release dates gives a minimum of 2.9.6, so ship 2.10.1.
   - The release pages show no year. The advisories show 2026, so these dates are 2026.

2. **Feed hosting (researchers disagreed).** One said `releases/latest/download/appcast.xml`, one said raw.githubusercontent, two said GitHub Pages. **Decision: GitHub Pages.**
   - "latest" goes live the moment a release is published, can't carry a beta channel, and has no history or rollback.
   - raw.githubusercontent needs commits on `main`, which this repo changes only through PRs, and it serves `text/plain`.
   - Pages gives a stable URL, git history and rollback, and `release.sh` can push to `gh-pages` outside the PR flow.
   - Pages isn't enabled on the repo yet; it has to be enabled once.

3. **How `generate_appcast` treats older items (confirmed in source).** In `generate_appcast/Appcast.swift` (`makeAppcasts`), the single `downloadURLPrefix` is applied to **every** archive in the folder (`for update in allUpdates { update.downloadUrlPrefix = downloadURLPrefix }`). `FeedXML.swift` `writeAppcast` removes feed items whose version isn't in `appcast.versionsInFeed`, which is derived from the archives present. A multi-item feed would therefore rewrite older items to the newest tag's URL. A **one-item feed per release**, built from a folder holding only the new DMG, is the right model.
   - https://github.com/sparkle-project/Sparkle/blob/2.x/generate_appcast/Appcast.swift
   - https://github.com/sparkle-project/Sparkle/blob/2.x/generate_appcast/FeedXML.swift

4. **Sparkle's XPC services: keep or remove.**
   - The sandboxing page lets non-sandboxed apps remove them, with an example script that deletes only Downloader.xpc and then re-signs the framework.
   - The documented manual signing order is Installer.xpc, then Downloader.xpc with `--preserve-metadata=entitlements`, then `Autoupdate`, then `Updater.app`, then the framework, each with `-o runtime` and never `--deep`.
   - https://sparkle-project.org/documentation/sandboxing/
   - **Decision: keep them and sign them.** That is less framework surgery, and they are never used because the sandbox keys stay unset.

5. **The helper after an update (sources really do conflict).**
   - The SDK header says otherwise. The local Xcode 26.6 SDK's `SMAppService.h`, lines 60–62: *"If an app updates either the plist or the executable for a LaunchAgent or LaunchDaemon, the SMAppService must be re-registered or it may not launch. It is recommended to also call unregister before re-registering if the executable has been changed."*
   - DTS says the opposite. In https://developer.apple.com/forums/thread/804561 Quinn says a `BundleProgram` daemon has only one copy, the one in the app. On the idea of the daemon exiting so launchd loads the new copy, he says "That's what I'd expect." He also asks to verify that the updater writes a new inode, which Sparkle's atomic swap does.
   - Reports of unregister/register being flaky (needing `sfltool resetbtm`; Xcode 16.4 vs 26.0.1) are user reports only, not confirmed by DTS.
   - **Decision:** exit-and-relaunch is the primary path. Unregister, delay, register is the fallback, used only if the new build doesn't answer. The end-to-end test in §11 must confirm which path actually works on macOS 26. Treat this as the highest-risk item.

6. **Info.plist keys and the `INFOPLIST_KEY_*` route.**
   - Xcode only maps Apple-defined keys from `INFOPLIST_KEY_*`. The SU* keys need a real Info.plist through XcodeGen `info:`. Xcode merges that file with the generated keys when `GENERATE_INFOPLIST_FILE=YES`.
   - That merge is standard Xcode 13+ behaviour, but I didn't find an Apple page that states it, so `build-app.sh` should assert the keys are present (see §3).

7. **Release-notes file convention.** The `generate_appcast` help text confirms `--embed-release-notes`, and that HTML files without DOCTYPE/body are embedded by default. The `.md` sidecar convention isn't on the publishing page. Use an **`.html` fragment** (`LD-Manager.html`) for certainty. It is embedded automatically and therefore covered by the feed signature.

8. **`minimumSystemVersion` format.** The publishing page says to use a three-part version (`26.0.0`). `generate_appcast` reads `LSMinimumSystemVersion` from the app itself, so no action is needed.

9. **`SUAllowsAutomaticUpdates`.** The docs say YES "allows automatic updates even when automatic checks are disabled". Leave it **unset**; it isn't needed.

---

## 2. Framework choice

Use **Sparkle 2**. A custom updater would have to re-implement atomic bundle replacement, a separate installer process, EdDSA plus code-signature validation, and authorization. Sources:
- Apple, *Updating Mac Software*: https://developer.apple.com/documentation/security/updating-mac-software
- Quinn on updater design: https://developer.apple.com/forums/thread/758329

Squirrel.Mac is Electron-oriented. The Mac App Store is impossible because the app isn't sandboxed. A Homebrew cask with `auto_updates true` and `livecheck strategy :sparkle` can be added later; it complements Sparkle and doesn't replace it. https://docs.brew.sh/Cask-Cookbook

---

## 3. Integration in this codebase

### 3.1 `App/project.yml`
```yaml
packages:
  LDManagerPackage:
    path: ..
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: 2.10.1          # .xcodeproj is gitignored, so Package.resolved is never committed; pin exactly
targets:
  LDManager:
    dependencies:
      - package: LDManagerPackage
        product: LDCore
      - package: Sparkle           # embedded and codesigned by Xcode (ad-hoc here; re-signed in build-app.sh)
    info:
      path: Info.plist             # XcodeGen writes App/Info.plist and sets INFOPLIST_FILE; commit it
      properties:
        SUFeedURL: https://roeehrl.github.io/ldmanager/appcast.xml
        SUPublicEDKey: "<base64 from generate_keys -p>"
        SUEnableAutomaticChecks: true
        SUAutomaticallyUpdate: true
        SUScheduledCheckInterval: 86400
        SUScheduledImpatientCheckInterval: 259200
        SUVerifyUpdateBeforeExtraction: true
        SURequireSignedFeed: true
        SUEnableSystemProfiling: false
        SUShowReleaseNotes: true
    settings:
      base:
        MARKETING_VERSION: "0.1.4"
        CURRENT_PROJECT_VERSION: "5"
        # keep all existing INFOPLIST_KEY_* lines and GENERATE_INFOPLIST_FILE: YES
```

Notes on these keys:
- **Do not set** `SUEnableInstallerLauncherService`, `SUEnableDownloaderService`, `SUAllowsAutomaticUpdates`, `SUEnableJavaScript` or `SUSignedFeedFailureExpirationInterval` (default 20 days; it is the failsafe for a lost key). Key semantics: https://sparkle-project.org/documentation/customization/
- **`SUScheduledImpatientCheckInterval` = 259200 (3 days)** instead of the default week. LD Manager lives in the menu bar and rarely quits, so the prompt should come sooner. It must be greater than the check interval, and it is configurable since 2.9.
- **Network access:** `xcodebuild` now has to resolve the package over the network. For reproducible builds, add `-clonedSourcePackagesDirPath build/SourcePackages` and run `-resolvePackageDependencies` once.

### 3.2 New file `App/Sources/Updater.swift`
```swift
import Sparkle
import SwiftUI

@MainActor @Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @ObservationIgnored private(set) var controller: SPUStandardUpdaterController!
    var canCheck = false
    var pendingVersion: String?            // drives the menu-bar badge and "Update ready" row
    @ObservationIgnored private var kvo: NSKeyValueObservation?
    weak var model: AppModel?              // to ask "is it safe to install now?"

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        kvo = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] u, _ in
            Task { @MainActor in self?.canCheck = u.canCheckForUpdates }
        }
    }
    var updater: SPUUpdater { controller.updater }
    func checkForUpdates() { updater.checkForUpdates() }

    // Privacy: never send a system profile, even if SUSendProfileInfo is set in defaults.
    nonisolated func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String] { [] }

    // Admin kill switch (see section 8).
    nonisolated func updater(_ updater: SPUUpdater, mayPerformUpdateCheck updateCheck: SPUUpdateCheck) throws {
        if UserDefaults.standard.bool(forKey: "UpdatesDisabled") {
            throw NSError(domain: "LDManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Updates are disabled by your organization."])
        }
    }

    // Staging feed for tests only (section 11). The signed feed and EdDSA still apply.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "LDMStagingFeedURL")
    }

    // Menu-bar app that rarely quits: install silently when idle, otherwise wait for quit.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        Task { @MainActor in
            self.pendingVersion = item.displayVersionString
            if self.model?.isIdleForUpdate == true {   // no main window, no sheet or editor, no busy operation
                UserDefaults.standard.set(true, forKey: "LDMRelaunchedForUpdate")
                immediateInstallationBlock()           // installs and relaunches with no UI
            }
        }
        return true                                    // we handle it; Sparkle still installs on quit
    }

    // Gentle reminders: badge the menu bar instead of a modal.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        Task { @MainActor in if !state.userInitiated { self.pendingVersion = update.displayVersionString } }
    }
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {}
    nonisolated func standardUserDriverWillFinishUpdateSession() { Task { @MainActor in self.pendingVersion = nil } }
}
```

Notes on this file:
- Delegate method names come from https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html and https://sparkle-project.org/documentation/gentle-reminders/.
- `isIdleForUpdate` is a new computed property on `AppModel` (see §3.4).
- **Swift 6 caution:** I did not verify whether Sparkle's headers carry main-actor annotations. The target is still `SWIFT_VERSION 5.0`. If strict concurrency complains, adjust the `nonisolated` and `Task` hops.

### 3.3 `App/Sources/LDManagerApp.swift`
- Add `@State private var updater = AppUpdater()` next to `model`, and set `updater.model = model` in `init` or `.task`.
- Pass `.environment(updater)` to `ContentView`, `SettingsView` and `MenuBarView`.
- Add an App menu item: `.commands { JobCommands(model: model); CommandGroup(after: .appInfo) { Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheck) } }`.
- **Menu bar label:** show a badge when `updater.pendingVersion != nil`. For example use `arrow.down.circle`, or add `.symbolRenderingMode` with a dot; the label already switches symbols for diagnoses.
- **Don't open the main window after a silent update relaunch:** use `.defaultLaunchBehavior(relaunchedForUpdate ? .suppressed : .automatic)` on the `Window` (macOS 15+). Read and clear `LDMRelaunchedForUpdate` in `init`. Window state restoration may still reopen it, so test this.

### 3.4 `App/Sources/MenuBarView.swift` and `AppModel`
- In the footer, next to Settings and Quit, add a **"Check for Updates…"** button that calls `updater.checkForUpdates()` and is disabled when `!canCheck`. Since 2.2 Sparkle activates the app for user-started checks, and 2.9.4 fixed front-most issues for background apps.
- When `pendingVersion` is set, show a row **"LD Manager x.y.z is ready — Restart to Update"** that calls `checkForUpdates()`. Sparkle then shows its "Install and Relaunch" UI for the staged update.
- Add `var isIdleForUpdate: Bool` to `AppModel`: no main window visible, `!isSheetOpen`, `editorTarget == nil`, and no busy job operations.

### 3.5 `App/Sources/SettingsView.swift`
- Rename the existing `Section("Updates")`, which is only the refresh picker, to **`Section("Job list")`** so it isn't confused with app updates.
- Add a `Section("Software Update")` that follows https://sparkle-project.org/documentation/preferences-ui/:

| Control | Behaviour |
|---|---|
| Toggle **"Check for updates automatically"** | Bound to local `@State` seeded from `updater.automaticallyChecksForUpdates`. Written back only in `.onChange`, from user action. |
| Toggle **"Download and install updates automatically"** | Bound to `automaticallyDownloadsUpdates`. `.disabled(!checks)`. |
| Pre-release channel | Leave it out of v1; add later with `allowedChannels(for:)`. |
| `LabeledContent("Last checked")` | `updater.lastUpdateCheckDate?.formatted(.relative(presentation: .named)) ?? "Never"`, refreshed `.onAppear`. |
| Button **"Check Now"** | Calls `checkForUpdates()`, disabled when `!canCheck`. |
| Caption | "Version 0.1.4 (5). Once a day LD Manager asks GitHub whether a newer version exists. Updates are verified with the project's signature and installed when you quit or when the app is idle. Nothing else is sent." |
| Managed state | If `UserDefaults.standard.objectIsForced(forKey: "SUEnableAutomaticChecks")` or `"SUAutomaticallyUpdate"` is true, disable the toggle and show "Managed by your organization". https://developer.apple.com/documentation/foundation/userdefaults/objectisforced(forkey:) |

Don't mirror these settings in `@AppStorage`; Sparkle persists them itself.

### 3.6 Helper changes (`Sources/LDCore/Helper.swift`, `Sources/LDManagerHelper/main.swift`, `AppModel.swift`)
1. **Build identity.**
   - In the helper's `main.swift`, capture `let helperBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"` **eagerly at process start**. The helper lives in `Contents/MacOS`, so `Bundle.main` is the app bundle. Reading at startup records the build the process actually started from; reading later after a swap would report the new build wrongly.
   - Have `version()` reply `"\(HelperPolicy.version)+\(helperBuild)"`, for example `"1+5"`.
   - The app compares against its own `CFBundleVersion`. An old helper replies `"1"` and therefore also counts as a mismatch, with no new selector needed.
2. **New additive XPC method** `func exitForUpdate(reply: @escaping (Bool) -> Void)`.
   - Reply `false` if an operation is running or `openConnections > 1`.
   - Otherwise reply `true`, then `DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }`.
   - Keep the protocol additive only. An old helper never answers the new selector; `HelperClient.call` already times out with a fallback.
3. **In `AppModel.checkHelperResponds()`**, at launch:
   - If the build doesn't match, call `exitForUpdate`.
   - If the old helper lacks the method (timeout), wait for its 30 s idle exit; the existing timer means at most about 35 s.
   - Then wait about 1 s, reconnect (launchd starts `Contents/MacOS/LDManagerHelper` from the new bundle on demand) and re-check the version.
   - Only if it still fails, run the existing `repairHelper()` (unregister, 2 s, register), at most once per launch.
   - Show "Helper build N (app M)" in Doctor.
4. **Freeze the helper identity forever:** label `io.github.roeehrl.ldmanager.helper`, the plist file name, `BundleProgram`, `--identifier io.github.roeehrl.ldmanager.helper`, and team MKNM96EU7J. A changed designated requirement triggers an AMFI launch-constraint failure that unregister doesn't fix (https://developer.apple.com/forums/thread/795022). Add a check in `release.sh` that `codesign -d -r- "$APP/Contents/MacOS/LDManagerHelper"` matches a committed `scripts/helper-requirement.txt`.
5. **Optional:** in `willInstallUpdateOnQuit`, call `exitForUpdate` before running the immediate install block.

### 3.7 `ldm`
- Nothing links Sparkle and nothing touches the network.
- `/usr/local/bin/ldm` is a symlink into `Contents/Helpers/ldm`, so it resolves to the new binary after the atomic swap. Running `ldm` processes finish on the old inode.
- Add a warning in `ldm` when the helper's build (from `version()`) differs from ldm's own build. That catches standalone copies from `ldm-macos.zip`, which Sparkle never updates.
- `ldm --version` should print the build.

---

## 4. `scripts/build-app.sh` changes

After the existing `cp` steps and **before** signing ldm, the helper and the app, add:
```bash
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FW/Versions/B/XPCServices/Installer.xpc"
  codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FW/Versions/B/Autoupdate"
  codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FW/Versions/B/Updater.app"
  codesign "${FLAGS[@]}" --sign "$SIGN_IDENTITY" "$FW"
fi
# then the existing ldm, helper and app lines; keep `codesign --verify --strict --deep` (verify only)
for k in SUFeedURL SUPublicEDKey SURequireSignedFeed; do
  /usr/libexec/PlistBuddy -c "Print :$k" "$APP/Contents/Info.plist" >/dev/null \
    || { echo "Info.plist is missing $k" >&2; exit 1; }
done
```

- **Why this is needed:** Xcode builds with `CODE_SIGN_IDENTITY=-`, so Sparkle's nested code is only ad-hoc signed. That fails notarization. On macOS 13+ Sparkle also skips the atomic swap and Gatekeeper scan when `Autoupdate`'s team doesn't match the update's team (researcher reading of `Autoupdate/SUPlainInstaller.m`, 2.x).
- **`FLAGS`** already contains `--force --options runtime --timestamp`. Never sign with `--deep`.
- **Ad-hoc dev builds** (`SIGN_IDENTITY=-`): hardened-runtime library validation may refuse an ad-hoc Sparkle.framework. If the app won't launch, drop `--options runtime` in the ad-hoc branch. This is unverified, so test it.

## 5. `scripts/release.sh` changes, step by step

The existing steps stay as they are: build, notarize the zip, staple the app, dmgbuild, codesign the DMG, notarize the DMG, staple the DMG, ldm zip, SHA256SUMS.

The DMG is the update archive. Its app is stapled and the DMG is Developer ID-signed, notarized and stapled. That is also exactly what Sparkle's key-rotation fallback needs under `SUVerifyUpdateBeforeExtraction` ("Key rotation remains possible using Apple Developer ID code-signed disk images as a fallback", customization page). No extra notarization is needed.

New steps after `SHA256SUMS.txt`:
```bash
TAG="v$VERSION"
SPARKLE_BIN="${SPARKLE_BIN:-build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}"
[ -x "$SPARKLE_BIN/generate_appcast" ] || { echo "Sparkle tools not found at $SPARKLE_BIN" >&2; exit 1; }

# 6. Helper identity guard
diff <(codesign -d -r- "$APP/Contents/MacOS/LDManagerHelper" 2>&1 | sed -n 's/^designated => //p') \
     scripts/helper-requirement.txt || { echo "Helper designated requirement changed" >&2; exit 1; }

# 7. Appcast: a one-item feed from a folder holding only this DMG (+ release notes)
STAGE="$OUT/sparkle"; mkdir -p "$STAGE"
cp "$OUT/LD-Manager.dmg" "$STAGE/"
cp "release-notes/$VERSION.html" "$STAGE/LD-Manager.html"   # HTML fragment, no DOCTYPE or body, so it is embedded
"$SPARKLE_BIN/generate_appcast" \
  --account ed25519 \
  --download-url-prefix "https://github.com/roeehrl/ldmanager/releases/download/$TAG/" \
  --link "https://github.com/roeehrl/ldmanager" \
  --full-release-notes-url "https://github.com/roeehrl/ldmanager/releases" \
  --embed-release-notes --maximum-deltas 0 \
  -o "$STAGE/appcast.xml" "$STAGE"
"$SPARKLE_BIN/sign_update" --verify "$OUT/LD-Manager.dmg" "$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$STAGE/appcast.xml")"

# 8. Publish assets first (or keep the existing manual `gh release create` step)
gh release create "$TAG" "$OUT/LD-Manager.dmg" "$OUT/ldm-macos.zip" "$OUT/SHA256SUMS.txt" --title "LD Manager $VERSION" --notes-file "release-notes/$VERSION.md"

# 9. Confirm the enclosure is live, with the exact length
LEN=$(curl -sIL "https://github.com/roeehrl/ldmanager/releases/download/$TAG/LD-Manager.dmg" | awk 'tolower($1)=="content-length:"{v=$2} END{print v}' | tr -d '\r')
[ "$LEN" = "$(stat -f%z "$OUT/LD-Manager.dmg")" ] || { echo "Asset length mismatch" >&2; exit 1; }

# 10. Only now publish the feed
git -C build/gh-pages pull -q || git worktree add build/gh-pages gh-pages
cp "$STAGE/appcast.xml" build/gh-pages/appcast.xml
git -C build/gh-pages commit -qam "appcast: $VERSION ($(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist"))"
git -C build/gh-pages push -q origin gh-pages
```

Notes:
- **Order:** sign the DMG with EdDSA only after `stapler staple`, which changes its bytes. The feed goes live only after the asset returns 200 with the right length.
- **Feed signing:** `generate_appcast` signs the feed and the embedded notes because the archived app has `SURequireSignedFeed`. After any hand edit, run `sign_update appcast.xml`. https://sparkle-project.org/documentation/publishing/
- **No phased rollout at launch.** The user base is small and fast fixes matter around Show HN. Later, add `--phased-rollout-interval 86400`. Critical updates and manual checks bypass it.
- **Commits:** the gh-pages commit message must contain no AI attribution (per the owner's global rule).
- **`--maximum-deltas 0`:** I haven't confirmed it cleanly disables deltas, but with a single archive in the folder no delta can be produced anyway.

### Key generation, storage and backup (one-time)
1. `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys` stores the key in the login keychain (service `https://sparkle-project.org`, account `ed25519`) and prints `SUPublicEDKey`. Paste that into `project.yml`.
2. `generate_keys -x ~/Desktop/ldm-sparkle.key`, then store the file in a password manager **and** an offline encrypted backup, and `rm -P` the plaintext. Never put it in the repo, `build/` or GitHub secrets. If CI ever signs, use `--ed-key-file -` from stdin; never the deprecated `-s`.
3. Back up the Developer ID `.p12` offline too. Sparkle accepts an update when **either** the old EdDSA key verifies it **or** the old designated requirement is satisfied (`SUUpdateValidator.m`, 2.x). So:
   - Each key alone is powerful; protect both.
   - Either key, but never both, can be rotated in a single release.
   - Losing both means users must reinstall by hand.
4. Harden GitHub: hardware-key 2FA, **immutable releases** enabled (https://github.blog/changelog/2025-10-28-immutable-releases-are-now-generally-available/), and tag rulesets.

## 6. Versioning policy
- `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) is the only number Sparkle compares. It must be a plain integer, increase on every build that is published anywhere (staging tests too), and never be reused.
- 0.1.4 is **5**.
- Sparkle refuses downgrades: `SUPlainInstaller` compares the extracted `CFBundleVersion`. `MARKETING_VERSION` is for display only (`sparkle:shortVersionString`).
- The helper and ldm builds come from the same number (§3.6).

## 7. Security settings summary
- Sparkle ≥ 2.9.6; ship 2.10.1.
- EdDSA key in Info.plist, `SUVerifyUpdateBeforeExtraction=YES`, `SURequireSignedFeed=YES`.
- HTTPS feed and HTTPS enclosures, with the DMG signed by Developer ID.
- No system profiling: Info.plist NO plus the delegate returning `[]`.
- No JavaScript in release notes; the default is NO.
- **Residual risk:** a signed feed doesn't stop a "freeze" attack, where someone with hosting control serves an old, validly signed feed. It cannot force a downgrade.
- Admins/MDM can override `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` through managed preferences. A source reading of `SUHost.m` says the security keys are read only from Info.plist.

## 8. Privacy wording

Replace README.md line 186, and the matching passages in **README.ja.md** and **README.zh-CN.md**:

> **Does it send anything anywhere?**
> Only to check for updates. About once a day, LD Manager downloads a small file (`appcast.xml`) from this project's GitHub Pages site. If a newer version exists, it downloads it from GitHub Releases and installs it when you quit or when the app is idle. These requests carry only what any download does: your IP address and a user agent naming the app and version (for example `LD Manager/0.1.4 Sparkle/2.10.1`). There are no identifiers, no system profile and no analytics, and GitHub's privacy statement applies. Every update must carry this project's signature, and older versions are refused. To turn it off, use Settings › Software Update, or run `defaults write io.github.roeehrl.ldmanager SUEnableAutomaticChecks -bool false`. The `ldm` command-line tool never connects to the network. Otherwise LD Manager reads launchd's state with `launchctl` and your plist files on disk.

Also:
- Add a FAQ entry for admins: a configuration profile for domain `io.github.roeehrl.ldmanager` with `SUEnableAutomaticChecks=false` and `SUAutomaticallyUpdate=false`, plus `UpdatesDisabled=true` to block manual checks too (enforced by the delegate in §3.2).
- Update the site copy (codonic.dev product page) the same way.
- Check the exact request headers once with a proxy before finalizing; Accept-Language and Accept-Encoding are unverified.

## 9. UX notes
- `SUEnableAutomaticChecks=YES` suppresses Sparkle's second-launch prompt. That is more aggressive than Rectangle, Ice or MacVim, so disclose it: one non-modal line in the existing helper onboarding or first-run area, "LD Manager keeps itself up to date (Settings › Software Update)", plus the Settings caption.
- Standard (non-admin) users, and root-owned copies (MDM or pkg installs), need authorization. Sparkle then downloads only and prompts for an admin password. That is expected; document it.
- Keep Sparkle's "Skip This Version" as it is. A manual check still offers a skipped version.

## 10. CLI implications
Covered in §3.7. Also update the release notes and README so they say `ldm-macos.zip` copies are not auto-updated, and that the `/usr/local/bin` symlink installed from Settings is.

## 11. End-to-end test plan

HTTPS is required (ATS and Sparkle), so don't test with a plain-HTTP localhost feed. Use a **staging feed on the real infrastructure**:

1. **Setup.**
   - Add the `feedURLString(for:)` override from §3.2, read from the `LDMStagingFeedURL` default.
   - Publish staging feeds at `https://roeehrl.github.io/ldmanager/staging/appcast.xml`.
   - Upload test archives to GitHub **pre-releases** (e.g. `v0.1.4-test.1`). Pre-releases don't move `releases/latest`, so the README download link is untouched.
   - Every test build consumes a fresh `CFBundleVersion`.
2. **Build A:** 0.1.4, build 5, signed, notarized and stapled through `release.sh`, with publishing to a pre-release. Install it in `/Applications` on a **clean macOS 26 VM**; Quinn recommends a VM because development-machine Launch Services and BTM state hide problems. Approve the helper. Install the `ldm` symlink.
3. **Build B:** build 6, also through `release.sh`, with `generate_appcast` pointed at the pre-release prefix and pushed to `staging/appcast.xml`.
4. On the VM:
   - Run `defaults write io.github.roeehrl.ldmanager LDMStagingFeedURL https://roeehrl.github.io/ldmanager/staging/appcast.xml`.
   - Run `defaults delete io.github.roeehrl.ldmanager SULastCheckTime`, then relaunch.
5. **Scenarios:**
   - (a) Menu "Check for Updates…" → install and relaunch.
   - (b) Silent path: auto-download, then quit, then reopen.
   - (c) Idle immediate install with the main window closed. Confirm the window does not reappear.
   - (d) Update while the helper is mid-operation and while `ldm list` is running.
   - (e) Standard (non-admin) user: download plus an authorization prompt.
   - (f) A tampered feed (edit one byte) is rejected, and a DMG signed with another key is rejected.
6. **Checks after each run:**
   - `ls -i` on `Contents/MacOS/LDManagerHelper` shows a new inode.
   - Doctor shows the helper reporting build 6 within about 2 s via `exitForUpdate`, with no reboot.
   - `sudo sfltool dumpbtm` shows one entry, still approved, with no new "Background Items Added" notification.
   - `log stream --predicate 'subsystem == "com.apple.backgroundtaskmanagement" OR process == "smd" OR process == "launchd"'` is clean.
   - `ldm --version` reports 6.
   - `codesign --verify --strict --deep` and `spctl -a -vv` pass on the updated app.
7. **Record which helper path worked:** exit only, or the unregister/register fallback. If exit alone fails on macOS 26, make re-registration the primary path when the build changes, as the header says.
8. Repeat on macOS 27 beta.

## 12. Risks and open questions for the owner
1. **Helper re-registration (high risk):** the SDK header and DTS disagree (§1.5). Only the VM test settles it.
2. **Feed URL is forever:** `roeehrl.github.io/ldmanager` vs a `codonic.dev` URL you control. Pages is recommended. If the github.io user site ever gets a custom domain, Pages issues a 301; Sparkle follows redirects, but verify then.
3. **Aggressive default:** silent install with no prompt. Accept it, or fall back to Sparkle's second-launch prompt with the auto-install box pre-checked (leave `SUEnableAutomaticChecks` unset)?
4. **Silent relaunch while idle:** acceptable, or only ever install on quit plus the 3-day prompt?
5. **Window suppression after relaunch** (`defaultLaunchBehavior`) and state restoration need testing.
6. **Key custody:** who holds the EdDSA backup, and where. Losing it together with the Developer ID strands every user.
7. **Bootstrap:** 0.1.3 users must download 0.1.4 manually. Say so in the 0.1.4 release notes and the launch post. Ideally ship 0.1.4 **before** the 2026-12-01 Show HN so launch-day users get updates.
8. **Ad-hoc builds** may not load Sparkle under the hardened runtime (§4).
9. **Swift 6 and Sparkle actor annotations** are unverified.
10. **macOS 26 BTM oddities** ("fullPath is nil", Full Disk Access lost after Sparkle updates until reboot; https://developer.apple.com/forums/thread/813148) have no root cause. The existing `.broken` and repair UI covers the helper side.
11. **Homebrew:** if a cask exists or is planned, add `auto_updates true` and `livecheck strategy :sparkle`.

## Sources
- Sparkle:
  - https://sparkle-project.org/documentation/
  - https://sparkle-project.org/documentation/customization/
  - https://sparkle-project.org/documentation/publishing/
  - https://sparkle-project.org/documentation/sandboxing/
  - https://sparkle-project.org/documentation/preferences-ui/
  - https://sparkle-project.org/documentation/gentle-reminders/
  - https://sparkle-project.org/documentation/programmatic-setup/
  - https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html
  - https://github.com/sparkle-project/Sparkle/releases
  - https://github.com/sparkle-project/Sparkle/security/advisories
  - https://raw.githubusercontent.com/sparkle-project/Sparkle/2.x/generate_appcast/main.swift
  - https://github.com/sparkle-project/Sparkle/blob/2.x/generate_appcast/Appcast.swift
  - https://github.com/sparkle-project/Sparkle/blob/2.x/generate_appcast/FeedXML.swift
  - https://github.com/sparkle-project/Sparkle/blob/2.x/Sparkle/SUUpdateValidator.m
  - https://github.com/sparkle-project/Sparkle/blob/2.x/Autoupdate/SUPlainInstaller.m
  - https://github.com/sparkle-project/Sparkle/discussions/2572
- Apple:
  - SMAppService.h in the local Xcode 26.6 SDK, lines 60–62
  - https://developer.apple.com/forums/thread/804561
  - https://developer.apple.com/forums/thread/783539
  - https://developer.apple.com/forums/thread/795022
  - https://developer.apple.com/forums/thread/813148
  - https://developer.apple.com/forums/thread/758329
  - https://developer.apple.com/documentation/security/updating-mac-software
  - https://developer.apple.com/documentation/foundation/userdefaults/objectisforced(forkey:)
- Other:
  - https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md
  - https://github.blog/changelog/2025-10-28-immutable-releases-are-now-generally-available/
  - https://docs.brew.sh/Cask-Cookbook

Repo files read (unchanged):
- /Users/tnt/git/ldmanager/App/project.yml
- /Users/tnt/git/ldmanager/scripts/build-app.sh
- /Users/tnt/git/ldmanager/scripts/release.sh
- /Users/tnt/git/ldmanager/App/Sources/SettingsView.swift
- /Users/tnt/git/ldmanager/App/Sources/LDManagerApp.swift
- /Users/tnt/git/ldmanager/Sources/LDCore/Helper.swift
- /Users/tnt/git/ldmanager/Sources/LDManagerHelper/main.swift
- /Users/tnt/git/ldmanager/README.md
