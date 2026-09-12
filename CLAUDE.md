# pancake — notes for whoever picks this up next

Read `README.md` for what it is and `DESIGN.md` for why. This file is the operational stuff.

**Working style (owner's standing preference):** commit at every natural checkpoint — you don't
need to ask. The remote is `git@github.com:samuelmarquis/pancake.git` (`origin`); push freely.
And the overarching directive: *always do the correct/hard thing, never the fast/easy/fix-it-later
thing.*

## Environment facts

- macOS 26.3, Apple Silicon, **Command Line Tools only — no Xcode, no signing identity.**
  Everything builds with `swift build` + `clang`; the driver is ad-hoc signed.
- `timeout` doesn't exist. To run the engine for N seconds: start it in the background,
  `sleep N`, `kill -INT <pid>` (SIGINT shuts down cleanly and destroys the aggregate).
- **The nix `audio-defaults` launchd agent is gone** (removed from `home.nix` 2026-09-11, `home-manager switch`d).
  It used to hard-pin output to Loopback and shove input off Bluetooth; pancake now does both — output via
  the default-output pin/follow, input via the **input lock** (`policy.lockInput` → the engine pins the
  system default input to the device feeding Pancake Mic and re-asserts it on `defaultInputChanged`). The
  old `~/.config/audio-pin-off` escape hatch no longer exists and isn't needed. If anything ever re-pins the
  default output on its own again, check `launchctl list | grep audio` — it should be empty of our stuff.
- Loopback 2.4.10 is still installed and is the fallback. Don't uninstall it — `MIGRATION.md`.
- The AirPods (`F0-04-E1-C9-6A-F8:output`, name `AÀÂÃÅÄĄ`) come and go; the phone steals them.

## Commands

```sh
make build                 # → .build/debug/pancake
make test                  # swift test with the -F flags CLT needs for swift-testing
make driver                # driver/build/Pancake.driver
sudo make install-driver   # needs a real terminal for the password; kills coreaudiod (launchd respawns it — kickstart is SIP-blocked)
make app && make run-app   # build/Pancake.app; `make stop-app` quits it via AppleScript (SIGTERM would skip the hand-back)
make install-app           # copy both apps → ~/Applications (stable paths); then menu → "Start at login"
make stage && make run-stage  # build/PancakeStage.app (faceless screen-share helper); `make stop-stage` quits it
tail -f ~/Library/Logs/pancake.log
.build/debug/pancake status | devices [--all] | graph | set-output <name>
.build/debug/pancake run [--output <name>] [--hub <name>] [--no-pin] [--no-follow] [--stats N] [--verbose]
.build/debug/pancake probe-aggregate <dev>... [--main <dev>] [--run N]
```

`swift test` without the flags fails with "no such module 'Testing'". Test files must not
`import Foundation` (the `_Testing_Foundation` cross-import overlay can't be found); put
Foundation-needing helpers in `PancakeCore` instead (see `Graph.jsonString()`).

## Architecture in one breath

`driver/Pancake.c` (GPL fork of BlackHole) gives the system three virtual devices: **Pancake**
(`Pancake_UID`, the default output, has the volume control), **Pancake Mic**
(`PancakeMic_UID`, what Discord records, no controls), and **Pancake Program**
(`PancakeProgram_UID`, a controls-free silent sink the Stage renders the shared program into —
reports `CanBeDefault* = false` so the system never picks it). All three are
`kObjectID_Device`/`Device2`/`Device3`, each keyed to its own ring buffer via
`pancake_device_index` (`gRingBuffer[0|1|2]`); adding a fourth means cloning the `Device3`
footprint (see `tools/`-style transform history / `git log`). `Engine` builds one private aggregate
device out of the hub + every device the graph references (real hardware as clock master,
drift compensation on the rest), installs one IOProc (`pk_ioproc`, C, no allocation/locks),
and the IOProc applies a `pk_matrix` of routes — `out[b][c] += in[b][c] * gain` — swapped in
atomically. `Graph` is the desired state (JSON at `~/.config/pancake/graph.json`); the engine
derives an effective graph per rebuild. The file is the IPC: CLI/UI write it, engine watches it.

## Invariants — don't break these

1. **All engine state mutates on `Engine.queue`.** HAL listeners, file watcher, public API — all hop onto it.
2. **Nothing in the program writes a gain.** Links default to unity; only the user changes them. The
   driver's Pancake volume is the user's (volume keys). The one exception, and it's deliberate: the
   engine holds the *routed* physical output's hardware volume at unity while it's the output (the phone
   rewrites the AirPods' otherwise), puts the old value back when it isn't, leaves it at Pancake's level
   on quit, and logs every write. `DESIGN.md` § Gain. Nothing else touches a physical volume.
3. **The IOProc is C and touches nothing Swift.** Matrices are freed only after the cycle counter
   has moved past the swap (see `drainRetiredLater`) or after IO is stopped.
4. **Rebuild, don't mutate, the aggregate.** And ignore `devicesChanged` when the relevant UID set
   hasn't changed — our own aggregate's create/destroy fires that notification at us.
5. `driver/` and `Sources/` share no code (GPL boundary).

## App notes

- `Sources/PancakeApp` is a SwiftPM executable; `make app` wraps it in `build/Pancake.app` with
  `packaging/Info.plist` (LSUIElement, bundle id `com.pancake.app`, Bluetooth + audio-capture usage strings).
- The app owns the engine. Menu selection → `graph.setOutput` → `engine.apply` + `store.save`. The file
  watcher ignores its own save (`g == graph`).
- Only one engine at a time: the CLI `run` and the app both build an aggregate with the same UID and both
  pin the default output. Stop one before starting the other.
- Bluetooth reconnect uses IOBluetooth `openConnection` (same as `blueutil --connect`). First use may
  prompt for Bluetooth permission for the app.
- **The app needs Microphone permission or it routes silence.** Reading any input stream — including
  our own Pancake device inside the aggregate — is "microphone access" to TCC, and a denied client gets
  zero-filled input with *no error*. The symptom is `health: … hub=0.000` in the app's log while a CLI
  probe (`pancake probe-aggregate Pancake --run 3`) reads audio from the same driver at the same moment.
  The app asks explicitly at launch (`AVCaptureDevice.requestAccess`) and logs `microphone access: …`.
  **The usage string is the actual fix**: without `NSMicrophoneUsageDescription` in the bundle Info.plist
  the app can never be granted and reads silent zeros forever. Once it's present and you grant once, the
  grant *survives* `make app` rebuilds — matched by bundle id `com.pancake.app` even though ad-hoc
  re-signing changes the cdhash (verified: relaunching a fresh build logs `microphone access: authorized`
  with no prompt). CLI tools inherit the terminal's grant. If it ever does come back denied:
  `tccutil reset Microphone com.pancake.app` and relaunch.
- Do not chase "clock phase" in the driver's loopback again. It is BlackHole's: reader and writer
  index the ring by sample time in the device's own timeline, which the HAL preserves for a sub-device
  even when it's drift-compensated inside an aggregate. Probes with either clock master read the hub
  fine. If the app reads zero and a probe doesn't, it's TCC (above), not the driver.

## Verified on this machine

- Aggregate streams are laid out sequentially per sub-device, in `fullSubDeviceList` order;
  formats are Float32 interleaved; the IOProc runs at 512 frames/cycle at 48 kHz.
  `kAudioObjectPropertyOwner` on aggregate streams is the aggregate itself (no owner attribution).
- `ActiveSubDeviceList` returns the underlying *device* IDs; `kAudioSubDeviceProperty*` on them → `'who?'`.
- Engine end-to-end with `--hub "Loopback Audio" --output "MacBook Pro Speakers"`: routes, IO, clean exit, no leaked aggregate.
- Driver loads ad-hoc signed. `Pancake` + `Pancake Mic` appear; the volume keys drive Pancake's control.
- macOS 26 lists the AirPods as two devices, `…:input` (24 kHz mono) and `…:output` (48 kHz stereo).
  Only `:output` goes in the aggregate and they stay at 48 kHz — **no headset-mode drop**.
- Pin + follow + hand-back all work with real AirPods; the user confirmed Control Center switching.
- iOS steals the AirPods regardless of our running IOProc. Can't be prevented from this side.
- App end-to-end: Music → Pancake → aggregate → AirPods, audible, once the Microphone grant is in place.
- **Three-bus streaming, verified live (2026-09-12).** `Pancake Program` (`PancakeProgram_UID`,
  `kObjectID_Device3`, a controls-free silent loopback — the Stage renders the shared app into it)
  works end to end. With the Stage tapping Ableton, `pancake probe-aggregate "Pancake Program"`
  read peaks ~1.0 while `"Pancake Mic"` read ~0.003 (no bleed); a live Discord *window*-share of the
  Stage got "green on both" — friends heard Ableton clearly, no echo. Stage renders into Program
  (not Pancake Mic). Adding Program did NOT churn the engine — it logged `devices changed: same set,
  ignoring` (Program isn't graph-relevant). (A later review fixed two *latent* driver bugs —
  `kAudioPlugInPropertyTranslateUIDToDevice` omitted Device3, and a dead ControlList copy-paste;
  both off the live path. Committed but not yet installed — `sudo make install-driver` at convenience.)
- **Stage is a faceless, menu-driven helper, verified live (2026-09-12).** It's an `.accessory` app
  (no Dock icon, no control panel): one chrome-free mirror window, **always parked off-desktop** at a
  1pt on-screen sliver — invisible to you but still composited and listed in Discord's window picker
  (Discord lists it by its `.titled` title; `canJoinAllSpaces` keeps it on Discord's current desktop;
  it matches the display's aspect so there are no letterbox bars). You drive it entirely from the menu
  bar's **Screen share** section (start/stop + audio-source picker), which writes
  `~/.config/pancake/stage.json` (`StageConfig`); the Stage watches that file and reconciles its tap —
  the file is the IPC, same pattern as the graph. A preferred app (Ableton) is auto-tapped the moment
  it becomes tappable (a `kAudioHardwarePropertyProcessObjectList` listener), one-shot until you
  choose otherwise. Quit it via the menu's **Stop screen share** or `make stop-stage`.
- The AirPods' *own* hardware volume (elements 1+2, no element 0) is rewritten by the iPhone when it
  steals them; with Pancake as the default output the volume keys drive Pancake, so that hidden gain
  just makes everything quiet (found at 0.5). `swift tools/setvol.swift F0-04-E1-C9-6A-F8:output 1.0`
  is the manual fix; the engine should hold the routed device at unity — see next steps.

## Not yet verified / next steps, in order

0. Hold the routed physical output at unity while it's the hub's output, re-assert if something (the
   phone) changes it, restore the old value on release/quit, log every write. This is the one deliberate
   exception to "pancake never writes a physical volume" — `DESIGN.md` § Gain.
1. Bluetooth reconnect in anger: AirPods stolen by the phone, resume playback on the Mac, watch the log
   for "asking Bluetooth to reconnect" and whether they come back. May need the Bluetooth TCC prompt.
2. ✅ **Start at login** — `make install-app` copies Pancake.app + PancakeStage.app to `~/Applications`
   (stable paths, no sudo), and the menu's **Start at login** toggle registers the menu app via
   `SMAppService.mainApp`. The Stage is *not* a login item — the menu launches it on demand, so the
   screen isn't captured until you actually screen-share. Register from the `~/Applications` copy (run
   that one, not a `build/` copy) so the login item points at the stable path.
3. Discord: link `input(BuiltInMicrophoneDevice)` → `mic` and a source for Ableton → `mic` in the graph;
   Discord records `Pancake Mic`. Today that source can only be the whole hub (everything playing);
   per-app needs process taps.
4. Process taps → `tap` nodes (TCC "System Audio Recording Only"). `CATapDescription` on macOS 26 has
   `bundleIDs`, so taps can be declared by bundle id rather than pid.
5. Sleep/wake soak. Sample-rate change on the master (e.g. DDJ-FLX4 at 44.1k) → rebuild path is
   untested.
6. Graph window. Timebox it.
