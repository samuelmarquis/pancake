# The coreaudiod CPU storm of 2026-09-13

What happened, how it was root-caused, and what changed. Kept because the symptom ("pancake made my
whole Mac slow") points at pancake, the cause is an Apple bug, and the trigger is pancake's own
development workflow — all three matter to whoever sees it next.

## Symptom

coreaudiod at 100–200% CPU for ~40 minutes. The menu and graph window crawled. Discord, Helium, Steam,
Quick Look, loginwindow and Control Center each burned 40–50% re-reading the audio device list. It
survived killing every pancake process, rolling the driver back to the previous build, and restarting
coreaudiod (a fresh one hit 200% within 3 s). Restarting AirPlayXPCHelper made mediaremoted and
universalaccessd join in. It stopped when Wi-Fi reconnected.

## Cause

**AirPlayXPCHelper re-registers every HAL plug-in instance it holds each time coreaudiod restarts, so
its registration count doubles per restart.** Measured with `tools/halstate.swift`, with AirPlayXPCHelper
started at 05:52:52 and nothing else changing:

| coreaudiod restarts since the helper started | `com.apple.AirPlayXPCHelper` registrations |
|---|---|
| 4 | 16 |
| 5 | 32 |
| after `sudo killall AirPlayXPCHelper coreaudiod` | 1 |

Every other plug-in — Apple's and `com.pancake.driver` — stayed at one registration throughout. The count
doesn't move without a restart.

coreaudiod walks the plug-in/device-manager list to answer device-list queries. The diagnostics during
the storm show exactly that as the hot path (`HALS_System::GetNumberPlugIns`,
`_CopyDeviceManagerList`, `HALS_ObjectMap::ReleaseObject`), every request tagged *originated by*
AirPlayXPCHelper. The helper that melted down had been running for 25 days — through weeks of
`make install-driver`, each of which restarts coreaudiod. 2ⁿ gets large fast; today's installs at 05:09
and 05:23 (and two more restarts during debugging) pushed it over the edge.

Why Wi-Fi mattered: AirPlay's plug-in instances republish their devices on network changes, so every
registration churned at once; and after the helper was restarted, coreaudiod still held the dead
helper's registrations (mediaremoted logged `HAL_HardwarePlugIn_ObjectHasProperty: no object` ~14×/s)
until the Wi-Fi reconnect made AirPlay tear down and republish.

## Ruled out by controlled tests (all calm)

Each was a coreaudiod restart with coreaudiod's CPU logged every ~2 s:

- restart alone, nothing of pancake's running
- pancake app + AirPlay from an iPhone to the Mac, no restart
- pancake app + AirPlay + restart (v3 driver)
- same with the v4 (four-device) driver installed as the restart
- same with the Stage's live Program→Stage aggregate open
- Ableton open, idle and processing

None stormed — because by then AirPlayXPCHelper had been restarted and its count was small. The storm
needs a large registration count, not any particular combination at the moment of restart.

Also cleared: the pancake driver's host process (`Core Audio Driver (Pancake.driver)`) sat at 0% CPU
throughout; no process taps or pancake aggregates leaked.

## What changed

- **`make install-driver` restarts AirPlayXPCHelper together with coreaudiod** (one `killall`), so the
  fresh helper registers once with the fresh coreaudiod. Driver installs can no longer compound the leak.
- **Detection.** `HALHealth` counts duplicate plug-in registrations. `pancake status` prints them; the
  engine logs a warning whenever the set changes (checked on every rebuild, which a coreaudiod restart
  triggers); the menu shows "Core Audio is degraded" with a copy button for the fix command.
- **`tools/storm-snapshot.sh`** captures the whole picture in ~20 s, every HAL/log step under a timeout.
- **pancake bugs the storm exposed, fixed:**
  - After a coreaudiod restart the engine asked the HAL to update its now-dead tap ("HAL refused the
    in-place update"), and while coreaudiod was still coming up, a burst of process-list changes kept
    postponing the rebuild for a minute. Now: `kAudioHardwarePropertyServiceRestarted` drops dead taps
    outright, `ProcessTap.isAlive` guards the retarget, and a debounced rebuild can be postponed by at
    most 2 s (`rebuildMaxLatency`).
  - The app did HAL reads on the main thread (device lists, tappable apps, volume) and the UI polled the
    engine with `queue.sync`. With coreaudiod slow, both froze the UI. Now all app HAL work runs on the
    app's background queue, and the engine's UI-facing reads (bus meters, recording state, plug-in
    health) come from a lock-protected snapshot that never waits on the engine queue.
  - Quit ran `engine.stop()` synchronously; with coreaudiod hung it never returned and the app had to be
    force-killed, skipping the default-output hand-back. Quit now waits at most 4 s, then exits.

## Still open

- **Pancake can be left as the system default output with no engine running.** macOS keeps a
  preferred-output list; pancake pins Pancake all day, so it ranks first. If the real default device
  disappears while pancake isn't running (AirPods leaving), macOS falls back to Pancake and you hear
  nothing. See TODO.md.
- **No control without pancake's driver loaded.** The doubling is almost certainly the helper's own
  reconnect logic (no other plug-in doubles), but it hasn't been measured with the driver uninstalled.

## Apple Feedback draft

> **AirPlayXPCHelper HAL plug-in registrations double on every coreaudiod restart, eventually pinning
> coreaudiod's CPU**
>
> macOS 26.3 (25D…), Apple Silicon.
>
> Each time coreaudiod restarts (`sudo killall coreaudiod`, or any HAL driver install), the number of
> `com.apple.AirPlayXPCHelper` entries in `kAudioHardwarePropertyPlugInList` doubles: measured 16 → 32
> across one restart, with AirPlayXPCHelper's pid unchanged. Other plug-ins stay at one entry. After
> enough restarts (an AirPlayXPCHelper with weeks of uptime on a machine where an audio driver was
> installed repeatedly), coreaudiod sits at 100–200% CPU in `HALS_System::GetNumberPlugIns` /
> `_CopyDeviceManagerList`, all audio clients spin in `HALC_ShellPlugIn::ProxyObject_PropertiesChanged`,
> and the system becomes sluggish until AirPlayXPCHelper and coreaudiod are restarted together.
>
> Steps: 1) note the count of `com.apple.AirPlayXPCHelper` in the plug-in list; 2) `sudo killall
> coreaudiod`; 3) count again — it has doubled; repeat.
> Expected: one registration regardless of restarts.
> Workaround: `sudo killall AirPlayXPCHelper coreaudiod` (both in one command) resets it to one.
> Attach: a `tools/storm-snapshot.sh` capture and the coreaudiod `.cpu_resource.diag` files.
