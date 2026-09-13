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
- pancake does the output *and* input pinning itself: output via the default-output pin/follow, input via
  the **input lock** (`policy.lockInput` → the engine pins the system default input to the device feeding
  Pancake Mic and re-asserts it on `defaultInputChanged`). If anything *else* on the machine re-pins the
  default output on a timer (a login agent, another virtual-audio app), it'll fight pancake — check
  `launchctl list | grep audio` and disable it.
- pancake needs no other virtual-audio app to run; it ships its own driver. If Loopback or similar is
  installed nothing conflicts, but pancake doesn't depend on it — it was only a bring-up fallback.
- A Bluetooth output device (AirPods and the like, UID such as `AA-BB-CC-DD-EE-FF:output`) can come and go
  — a paired phone can steal it; the engine asks for a reconnect but can't force one.

## Commands

```sh
make build                 # → .build/debug/pancake
make test                  # swift test with the -F flags CLT needs for swift-testing
make driver                # driver/build/Pancake.driver
sudo make install-driver   # needs a real terminal for the password; kills coreaudiod *and* AirPlayXPCHelper (launchd respawns both — see below)
make app && make run-app   # build/Pancake.app; `make stop-app` quits it via AppleScript (SIGTERM would skip the hand-back)
make install-app           # copy both apps → ~/Applications (stable paths); then menu → "Start at login"
make stage && make run-stage  # build/PancakeStage.app (faceless screen-share helper); `make stop-stage` quits it
tail -f ~/Library/Logs/pancake.log
.build/debug/pancake status | devices [--all] | graph | set-output <name>
.build/debug/pancake run [--output <name>] [--hub <name>] [--no-pin] [--no-follow] [--stats N] [--verbose]
.build/debug/pancake record [--source hub|tap:<bundleID>|<device>] [--seconds N] [--to <path>]   # proves the recorder/tap path
.build/debug/pancake probe-aggregate <dev>... [--main <dev>] [--run N]
sudo tools/storm-snapshot.sh  # coreaudiod misbehaving? capture everything first (→ ~/Desktop/pancake-storm-*)
```

`swift test` without the flags fails with "no such module 'Testing'". Test files must not
`import Foundation` (the `_Testing_Foundation` cross-import overlay can't be found); put
Foundation-needing helpers in `PancakeCore` instead (see `Graph.jsonString()`).

## Architecture in one breath

`driver/Pancake.c` (GPL fork of BlackHole) gives the system four virtual devices: **Pancake**
(`Pancake_UID`, the default output, has the volume control), **Pancake Mic**
(`PancakeMic_UID`, what Discord records, no controls), **Pancake Program**
(`PancakeProgram_UID`, the screen-share bus: a controls-free silent sink the *engine* mixes into,
`NodeKind.program` in the graph), and **Pancake Stage** (`PancakeStage_UID`, the Stage's private
render target — it plays Program back into this as its own process output). Program and Stage
report `CanBeDefault* = false` so the system never picks them. They're
`kObjectID_Device`/`Device2`/`Device3`/`Device4`, each keyed to its own ring buffer via
`pancake_device_index` (`gRingBuffer[0…3]`); adding a fifth means cloning the `Device4` footprint
(`git show` the Device4 commit — it was applied by a self-checking transform that asserts every
edit's match count). `Engine` builds one private aggregate
device out of the hub + every device the graph references (real hardware as clock master,
drift compensation on the rest), installs one IOProc (`pk_ioproc`, C, no allocation/locks),
and the IOProc applies a `pk_matrix` of routes — `out[b][c] += in[b][c] * gain` — swapped in
atomically. `Graph` is the desired state (JSON at `~/.config/pancake/graph.json`); the engine
derives an effective graph per rebuild. The file is the IPC: CLI/UI write it, engine watches it.

**Buses** are the one node kind with a port on both sides (`NodeKind.bus`, `isSource && isSink`).
The IOProc has `PK_MAX_BUSES` (8) preallocated stereo scratch buffers and evaluates the matrix in
stages: routes reading device/tap inputs first (they may target buses, recorders or outputs), then
each bus in dependency order — `process_bus` (the self-authored compressor: feed-forward,
stereo-linked peak detector, soft knee, log-domain attack/release smoothing; then makeup and trim)
followed by the routes that read that bus. `MatrixCompiler` orders buses with Kahn's algorithm so
bus→bus is a DAG; a cycle drops the links that close it, with a warning. `BusParams` live in
`Graph.buses` (keyed by node id, written only when non-default) and are *not* topology, so editing
the compressor hot-swaps the matrix like a gain; the compressor's envelope lives in the `pk_context`
per slot, so a swap doesn't reset it. Time constants are baked to per-sample coefficients by the
compiler for the run's sample rate. `Engine.busMeter` exposes last-cycle gain reduction + peak.
Proven by `BusTests` (sample-exact summing/fan-out, trim, the gain computer at 20:1, attack smoothing).

**The engine owns every process tap — one per app, ever.** Two Core Audio taps on the same process
family fight and one goes silent (seen live: the Stage's tap of Helium was starved the moment the
engine also tapped Helium for a recorder; whichever tap was created last won, which is why "it worked
after a restart"). So nothing else in pancake creates taps: the Stage is a dumb repeater (Program →
Stage device), and one tap fans out to the recorder, the mic and Program as the graph wires it. A tap
follows its app's processes *in place* (`ProcessTap.update` sets `kAudioTapPropertyDescription` on
the live tap, same UUID, so the aggregate never notices): helpers spawning, the app quitting and
relaunching — no rebuild, no glitch. Only "an app we wanted but couldn't tap is now running" rebuilds.
The engine listens to `kAudioHardwarePropertyProcessObjectList` for all of this.

**Recorders** are sink nodes that aren't devices (`NodeKind.recorder`). A route whose `out_buffer`
carries `PK_REC_FLAG` targets a `pk_context` recorder slot instead of an aggregate output stream; the
IOProc mixes it into a preallocated stereo scratch and, while armed, `memcpy`s it into a lock-free
SPSC ring (all allocation at context creation — invariant #3 holds). `RecordingSession` drains the
ring to a 24-bit WAV via `ExtAudioFile` on a 0.1s timer on the *engine* queue (never the RT thread);
the ring absorbs disk jitter. Up to `PK_MAX_RECORDERS` (4) stereo recorders. The engine assigns each
recorder node a slot at every matrix compile (`syncRecorderSlots`); recordings survive a rebuild
because the ring lives in the context, not the matrix.

**Never restart coreaudiod on its own — restart AirPlayXPCHelper with it.** Apple's AirPlayXPCHelper
re-registers every HAL plug-in instance it holds whenever coreaudiod comes back, so its registration
count *doubles* per coreaudiod restart (measured 16 → 32; `sudo killall AirPlayXPCHelper coreaudiod`
→ 1). Weeks of driver installs grew it until coreaudiod pinned the CPU for the whole machine
(2026-09-13, write-up in `COREAUDIOD-STORM.md`). `make install-driver` now kills both in one `killall`.
`pancake status` shows duplicate plug-in registrations, the engine logs them, the menu warns. If you
ever need to bounce coreaudiod by hand, use the two-name `killall`.

## Invariants — don't break these

1. **All engine state mutates on `Engine.queue`.** HAL listeners, file watcher, public API — all hop onto it.
   **But the UI never waits on it**: anything the UI polls comes from the engine's lock-protected
   `Snapshot`, and the app does its own HAL work on its background queue, not the main thread —
   coreaudiod can stall a single HAL call for seconds, and a main thread waiting on it freezes the app.
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
  `kObjectID_Device3`, a controls-free silent loopback) works end to end: with Ableton rendered into
  it, `pancake probe-aggregate "Pancake Program"` read peaks ~1.0 while `"Pancake Mic"` read ~0.003
  (no bleed); a live Discord *window*-share of the Stage got "green on both" — friends heard Ableton
  clearly, no echo. (That verification was with the Stage tapping Ableton itself; the tap has since
  moved into the engine — see "The engine owns every process tap" above — and the Stage now reads
  Program and renders it into the fourth device, **Pancake Stage** (`PancakeStage_UID`,
  `kObjectID_Device4`). The repeater path needs the Device4 driver installed: `sudo make
  install-driver`; the Stage logs `no stage device` and retries on the next devices-changed until it is.)
- **Stage is a faceless, menu-driven helper, verified live (2026-09-12).** It's an `.accessory` app
  (no Dock icon, no control panel, **no configuration**): one chrome-free mirror window, **always
  parked off-desktop** at a 1pt on-screen sliver — invisible to you but still composited and listed in
  Discord's window picker (Discord lists it by its `.titled` title; `canJoinAllSpaces` keeps it on
  Discord's current desktop; it matches the display's aspect so there are no letterbox bars). The menu
  bar's **Screen share** section is start/stop + what's being shared; the **source** is the graph —
  wire anything (app taps, the hub, a mic, each with its own knob) into the **Pancake Program** node
  and the engine mixes it there. There is no `stage.json` any more (an old one is folded into the
  graph as `tap → program` on the app's next launch, then deleted). Quit the Stage via the menu's
  **Stop screen share** or `make stop-stage`.
- The AirPods' *own* hardware volume (elements 1+2, no element 0) is rewritten by the iPhone when it
  steals them; with Pancake as the default output the volume keys drive Pancake, so that hidden gain
  just makes everything quiet (found at 0.5). `swift tools/setvol.swift AA-BB-CC-DD-EE-FF:output 1.0`
  is the manual fix; the engine should hold the routed device at unity — see next steps.
- **Process taps capture the whole bundle-id family, verified live (2026-09-13).** Chromium/Electron
  apps (Helium and other browsers, Discord, Slack) render audio in a *helper* process
  (`net.imput.helium.helper`, `com.hnc.Discord.helper.Renderer`), not the main bundle — so tapping just
  the main process object captured silence. `ProcessTap.create` now taps a stereo mixdown of the whole
  family (`<bundle>` + `<bundle>.*`), and `tappableApps()` hides helpers whose parent app is listed (and
  the ● "playing" dot reflects any family member). Proven: `pancake record --source tap:com.hnc.Discord`
  captured Discord at −2.4 dBFS while its audio came from `…helper.Renderer` (old code → silence).
  That fix is also what *exposed* the two-tap conflict (both taps used to be silent for this reason,
  so they never visibly fought): with the engine tapping Helium for a recorder and the Stage tapping
  it for the share, `probe-aggregate "Pancake Program"` read 0.000 while the app ran and 0.888 the
  moment it was stopped. Hence "the engine owns every tap".
- **Buses + the compressor, verified live (2026-09-13).** CLI engine, `tap:QuickTime → bus → mic`,
  QuickTime playing a −54 dBFS tone (0.002): bus trim ×4 → `probe-aggregate "Pancake Mic"` read 0.008;
  editing the graph file to turn the compressor on (threshold −70, 20:1, instant) logged `matrix swapped
  (gains changed)` — no rebuild — and Mic read 0.001 (−15 dB of reduction on top of the trim, as the
  gain computer predicts); off again → 0.008. Note for scripted tests: the graph watcher is a
  *directory* source, so replace the file atomically (`mv` a temp file in) — an in-place `cp` is invisible.
- **Taps follow their app in place, verified live (2026-09-13).** CLI engine with
  `tap:com.apple.QuickTimePlayerX → mic`, QuickTime playing a −54 dBFS tone: `probe-aggregate "Pancake
  Mic"` read 0.002; quit QuickTime → *no rebuild*, Mic read 0.000; relaunch → log `now capturing 1
  process(es) (in place)`, still no rebuild, Mic read 0.002 again. The in-place
  `kAudioTapPropertyDescription` update works on macOS 26.3. (A scratch app that never registers with
  LaunchServices shows up as a HAL process with an *empty* bundle id — use a real bundled app to test.)
- **Recorder, verified live (2026-09-12).** `pancake record --seconds 6` of the hub while a sound
  played wrote a valid 2ch/48k/24-bit WAV, 6.005 s, peak −28.9 dBFS. The RT ring is also covered by a
  sample-exact unit test (`RecorderRingTests`) that pumps known audio through `pk_ioproc` and reads it
  back. In the UI: add a Recorder node, wire a source in, hit record.

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
5. Sleep/wake soak. Sample-rate change on the master (e.g. a 44.1 kHz interface) → rebuild path is
   untested.
6. ✅ **Graph window** — the menu's **Show graph…** opens a pipewire-style patchbay
   (`Sources/PancakeApp/GraphEditor*.swift`). Sources (Pancake, inputs, app taps) on the left, sinks
   (outputs, Pancake Mic, **Pancake Program**) on the right; **one bus port per side** (L/R is fungible
   — a connection is a whole stereo/mono bus, drawn as bundled strands, never split). Drag between
   ports to route; the mapping is chosen for you (mono fans to both, stereo sums to mono, else
   straight). Wires draw in one `Canvas` with a **colour gradient** blending the source node's hue into
   the sink's (blended in **OKLCH** — `ColorBlend.swift` — so cross-wheel pairs stay vivid instead of
   greying out in the middle; Mixbox was declined as CC-BY-NC/GPL-incompatible); live edges solid,
   waiting edges dashed + dim. **Gain is an in-place knob**: hover a wire,
   a **ring-gauge knob** (arc open at the bottom, filled to the current gain, dB in the centre) appears
   at its midpoint — drag to set gain, double-click for unity. `⌫` removes the hovered wire (or hovered
   node; nodes also have a hover ✕). **Re-drawing a wire that already exists removes it** (toggle) — that
   goes for the screen-share edge too. Add nodes from the top-bar palette **or right-click the canvas**
   (drops the node at the cursor); drag nodes, pan the canvas, **Tidy** snaps every node onto the dot
   grid (it aligns, it doesn't re-column). Edits apply to the engine at once and persist to `graph.json`;
   **node positions live in a separate `~/.config/pancake/graph-layout.json`** so the IPC stays clean.
   **Screen-share is integrated**: the **Pancake Program** node is a real sink (`NodeKind.program`,
   mirror of `mic`); whatever you wire into it is what the stream carries, and the engine does the
   mixing. **Buses** sit mid-canvas (three columns once one exists; a new bus drops below everything
   so it overlaps nothing) with a port on each side; the card has a COMP toggle, a live GR/peak
   readout and a settings popover (sliders edit `BusParams` live). Liquid-glass buttons where the CLT SDK has them; top bar sits on the traffic-light row
   (its legend drops out when the window is narrow); the window opens fitting a tidied graph and shrinks
   much smaller. Remaining polish if wanted: zoom, multi-select, marquee.

   Deliberately NOT done — **plugin (AU/VST/CLAP) inserts in the graph.** It would break invariant #3:
   the IOProc is pure C gain-routing plus our own DSP (no alloc/locks/ObjC/Swift), and hosting a plugin
   means calling its render inside that callback. Doing it RT-safely is a separate project (an
   out-of-line render chain on rings), not a contained change — see `TODO.md` for the blast radius.
   The bipartite break it needs (both-sides nodes) is already done by the bus node.
