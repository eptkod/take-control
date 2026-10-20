# Take Control: Handoff

## What it is
Take Control is an **EXTREMELY lightweight** fan control app for Apple Silicon Macs.

## Scope (all of it)
1. Display CPU temperature(s).
2. One slider to control fan speed.

Nothing else. No graphs, no profiles, no preferences window, no auto-update, no telemetry.

## Constraints
- **Lightweight is the top priority.** This means a tiny binary, near-zero idle CPU, a small memory footprint and no background polling beyond a slow timer (about 2s) that only runs while the UI is visible.
- Apple Silicon only (arm64). No Intel support and no universal binary.
- Prefer native Swift with AppKit or SwiftUI, and no third-party dependencies. No Electron or web views.
- A single small window or menu bar item is enough.

## Rules
- **Always rebuild the .app when you finish any change**: run `./build.sh`, then check that it printed `Built build/Take Control.app`. This applies to code, `Info.plist` and asset changes. If you changed anything in `Branding/`, run `Branding/render.sh` first. Don't report work as done while `build/Take Control.app` is out of date.

## Suggested approach (to verify, not yet validated)
- **Temperatures:** read the CPU sensors through the IOKit HID event system (`IOHIDEventSystemClient`, temperature usage page), or through SMC keys via `AppleSMC` where available. Check which works on the target macOS version.
- **Fan control:** write the target RPM through SMC keys (for example `F0Tg`, `F0Mn`, `F0Mx`, and the mode or unlock keys). Writing on Apple Silicon needs root, so plan a minimal privileged helper (`SMAppService` daemon) or a sudo-launched binary. Keep that part as small as possible.
- **Safety:** clamp the slider to the fan's reported min and max RPM. Restore automatic fan control on quit and on crash or termination, so the fans can never get stuck at a low speed.
- **UI:** a temperature readout and a slider. Fan RPM readback is optional.

## Open questions
- Menu bar popover or a standalone window? The popover is lighter and is the default if there is no preference.
- How is the privileged helper installed and distributed (signed or notarized, or just built locally)?
- Which macOS versions and which M-series chips need to be supported?

## Status
v1 is built: `./build.sh` produces `build/Take Control.app` (about 160 KB of code plus about 700 KB of app icon, arm64, ad-hoc signed).

Decisions taken on the open questions:
- **Small window plus a menu bar icon** (`LSUIElement`, so there is no Dock icon), plain AppKit with no SwiftUI. Closing the window only hides it: the app keeps running and keeps holding the fan. Clicking the menu bar icon shows a read-only menu with the CPU temperature and each fan's RPM and mode (Auto or Manual), refreshed every 2s only while the menu is open. From there it can open the window, where all the fan controls are, or quit. Quitting hands the fan back to macOS. Idle footprint is about 14 MB and 0% CPU. The 2s timers run only while the window or the menu is visible.
- **Helper:** `tc-helper` is a small C program bundled in the app. The first time the slider leaves "Auto", the app asks for an admin password once and installs it setuid root at `/Library/PrivilegedHelperTools/com.takecontrol.helper`. It is reinstalled if the bundled copy changes. It was built locally, so it is not notarized. SMAppService was skipped because it needs a real Developer ID.
- **Support:** macOS 13 or later on any M-series chip. Temperatures come from the HID `PMU tdie*` sensors, which work on M1 to M4. Fans use the generic `F<n>Md`/`F<n>Tg` keys, plus `Ftst` where that key exists.

Verified on an M2 MacBook Pro (Mac14,7) running macOS 27.0.1: temperature reads (16 sensors) and fan min/max/actual readback.
**Not yet verified:** the fan writes, because they need root and the admin prompt. Test them by hand: move the slider, check that the RPM readback follows, then quit or `kill -9` the app and check that the fan goes back to auto.

## Layout
- `Sources/smc.c`: AppleSMC read and write
- `Sources/temps.c`: HID CPU temperatures
- `Sources/helper.c`: the privileged helper. It reads per mille levels or `auto` on stdin and restores auto on EOF or a signal, so an app crash cannot leave the fans in manual mode. Every 5s it re-applies manual mode if the system took it back, for example after sleep.
- `Sources/main.swift`: the window (controls) and the menu bar item (read-only temperature and RPM). The slider's far left is Auto, and the rest maps onto each fan's min..max RPM.
- `Branding/`: SVG masters for the app icon, the menu bar glyph and the logo, plus `render.sh`, which regenerates `Resources/`. See `Branding/README.md`.
- `Resources/`: prebuilt `AppIcon.icns` and the `MenuBarIcon` template PNGs, which `build.sh` copies into the bundle.
- `dmg.sh`: runs `build.sh`, then packages `build/TakeControl-<version>.dmg` for release.
- `docs/screenshots/`: the screenshots used in `README.md`.

## Safety
- Overheat warning: one always-on 10s timer (`AppDelegate.checkOverheat`, skipped on fanless Macs) checks the hottest CPU sensor and the fans, even with no UI open. If the CPU is at or above 100 °C while a fan is stopped or in the bottom quarter of its range, on two checks in a row, the menu bar icon turns into a red warning triangle and a critical alert pops up in front of everything with a beep. In manual mode the alert offers "Return Fan to Automatic". The warning clears below 90 °C. The thresholds are in `enum Overheat`.
- The fan target is always clamped between `F<n>Mn` and `F<n>Mx`.
- Auto is restored when the app quits, when the helper sees stdin close (crash or kill of the app), on SIGTERM, SIGINT, SIGHUP or SIGQUIT to the helper, and at the next app launch if the fans were found in manual mode.
- Remaining gap: a `kill -9` of the helper itself leaves manual mode on until the app is relaunched.
