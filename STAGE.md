# Pancake Stage — design proposal (next leg)

*Written 2026-09-12, after the compositor concept was proven live in Discord.*

Read `DESIGN.md` for the audio architecture and `CLAUDE.md` for operational notes. This is the
plan for finishing **Pancake Stage**: the piece that lets you screen-share your whole desktop on
Discord with clean stereo app-audio and **no echo**.

---

## Status (updated 2026-09-12) — DONE and verified live; the Stage is a faceless menu-driven helper

The dedicated **Pancake Program** bus exists and the Stage renders into it. Verified end to end:
with the Stage tapping Ableton, a probe read **Pancake Program at peaks ~1.0** while **Pancake Mic
read ~0.003** (no bleed); a live Discord window-share got **"green on both"** — friends heard
Ableton clearly, no echo. Since then the Stage became a **faceless helper driven entirely from the
menu bar** — also verified streaming live.

- ✅ **#1 Pancake Program device** — driver `kObjectID_Device3`, installed, verified. (A later code
  review fixed two *latent* driver bugs — see repo state; they await a `sudo make install-driver`.)
- ✅ **#2 App picker + auto-tap** — pick the app to share; a preferred app (Ableton) is auto-tapped
  the moment it becomes tappable, one-shot until you choose otherwise.
- ✅ **#3 Config source-of-truth** — done via a dedicated **`stage.json` IPC** (StageConfig /
  StageStore), not the graph. The menu bar and the Stage are thin views over the file. Folding the
  program into the graph proper remains optional (see below).
- ✅ **#4 Menu app** — ignores the stage aggregate; gained a **Screen share** section that
  starts/stops the Stage and picks the source.
- ✅ **#5 Polish** — chrome-free, aspect-matched, all-Spaces mirror window, always parked off-desktop
  (invisible but shareable); faceless `.accessory` Stage (no control panel, no Dock icon); upright
  menu icon. Remaining nice-to-haves (multi-display, multi-app sum) below.

The rest of this doc is the original design writeup, kept for context; completed items are marked.

---

## Why Stage exists (the problem, settled)

Discord's full-screen "share sound" captures **all system audio** on your Mac — including the
call's *incoming* audio (your friends' voices, which your Mac has to play so you can hear them).
So a full-screen share re-broadcasts everyone back to themselves. This is **not** an audio-routing
bug and **no device router can fix it** (Loopback couldn't either) — the friends' voices are
system audio, and Discord grabs all of it. Verified: moving Discord's *output* to another device
did nothing; the echo persisted.

The one escape Discord gives us: a **window/app share captures only that app's process audio**.
And — the decisive probe result — **it captures that process's audio even when it's inaudible to
you** (rendered to a silent device). So: build one app whose *window* shows the desktop and whose
*process* emits the clean program mix. Window-share that app → full desktop video + clean stereo,
and the call audio is never in scope.

## What already works (v0, proven live)

- **Video**: `Sources/PancakeStage` mirrors the main display via ScreenCaptureKit, excluding its
  own window (no recursion). Confirmed clean.
- **Audio**: `StageAudio` taps a chosen app (hardcoded `com.ableton.live`) via `PancakeCore.ProcessTap`,
  builds a private aggregate `[sink + tap]`, and a copy IOProc renders the tapped audio into a sink
  device — currently **Pancake Mic**. Discord window-shares the Stage → friends hear clean stereo
  Ableton, no echo. **Confirmed live in a real call.**
- **Signing**: both apps now sign with a stable self-signed identity ("Pancake Dev"), so TCC grants
  (Microphone, Screen Recording) survive rebuilds. No more permission churn.

### The v0 wart to fix — ✅ FIXED
The v0 Stage rendered into **Pancake Mic**, which is also Discord's *voice* input, so the program
(Ableton) bled into the voice channel — mono, voice-processed — underneath the clean stream. Fixed:
the Stage now renders into the dedicated **Pancake Program** bus (item #1 below), which nobody
monitors and which is not a voice input. Verified: Pancake Mic reads silence while Program is loud.

---

## Target architecture: three buses + the Stage

```
   apps (Ableton, music, Discord incoming)
        │
        ▼
   ┌──────────┐   monitor
   │ Pancake  │ ─────────────▶ AirPods        (what YOU hear)
   └──────────┘

   built-in mic ───────────▶ ┌────────────┐  voice
                             │ Pancake Mic │ ─────▶ Discord mic   (your voice, voice channel)
                             └────────────┘

   tap(Ableton) ──────────▶ ┌──────────────┐        (Stage renders here; silent — nobody monitors it)
   [+ other chosen apps]    │Pancake Program│
                            └──────────────┘
                                   ▲
                                   │ rendered by
                            ┌─────────────┐  video: desktop mirror
                            │Pancake Stage│ ─────────▶  window-shared in Discord
                            └─────────────┘  audio: the Program mix, as its own process
```

Three clean buses: **Pancake** = you hear, **Pancake Mic** = your voice, **Pancake Program** = the
stream. Stage consumes Program (renders it as its process) + mirrors the desktop.

A note that shaped the design: **the Stage must render the program audio itself** — window-share
captures the *shared app's* process, so pancake's engine rendering it wouldn't help. Hence the Stage
self-taps and renders. The graph is the *config* (which apps are in the program); the Stage is the
*executor*.

---

## The build items

### 1. `Pancake Program` — a silent sink device (driver) — ✅ DONE
- **Why**: give the Stage a place to render that nobody monitors, so the program never bleeds into
  the voice channel (kills the v0 wart) and the mental model stays three clean buses.
- **What**: add a third device to `driver/Pancake.c` — a silent loopback (or output-only) device,
  UID `PancakeProgram_UID`, no volume control. Mechanical BlackHole boilerplate: extend the
  per-device arrays (`gRingBuffer[3]`, sample-time/host-time arrays), add the object IDs, streams,
  and registration, and the `pancake_device_index` mapping.
- **Cost**: driver rebuild + one `sudo make install-driver` (coreaudiod restart, ~1 s of no audio).
  Tolerable now that Touch ID handles sudo.
- **Then**: `StageAudio.sinkUID = "PancakeProgram_UID"` (one line) — no more Pancake Mic bleed.
- **Rejected alternative**: reuse Pancake Mic + move Discord voice to the built-in mic. Works with
  no driver change but is semantically muddy and repurposes a device by its old name. Not worth it.

### 2. App picker in Stage (stop hardcoding Ableton) — ✅ DONE
- **Why**: you should choose what to share; Ableton is just today's default.
- **What**: a small control in the Stage window (an `NSPopUpButton` or a menu) listing tappable
  apps (`ProcessTap.processes()` ∩ regular running apps, the logic drafted in the removed AppModel
  code — recover from git/scratchpad). Selecting one restarts `StageAudio` on that bundle id.
- **Stretch**: share **multiple** apps (Ableton + a browser for reference tracks) — the aggregate
  already supports multiple taps; the copy IOProc becomes a sum.

### 3. Config source-of-truth — ✅ DONE (via `stage.json`, not the graph yet)
- **What shipped**: a dedicated `StageConfig { bundleID }` persisted at `~/.config/pancake/stage.json`
  (`StageStore`, same FileWatcher/atomic-write/ignore-own-save pattern as the graph). The menu bar
  writes it; the Stage watches it and reconciles its audio tap to match. The file *is* the IPC, so
  the menu, the Stage, the CLI and a text editor all drive one source of truth.
- **Still optional — fold into the graph proper**: represent the program as `tap` nodes routing to a
  `Program` sink in `graph.json`, so it composes with the eventual graph editor. Reuses `Graph`,
  `setTap`. **Open question** (unchanged): the engine and the Stage would both tap the same app —
  harmless but wasteful; decide whether the Stage is the sole tap owner for the program.

### 4. Redeploy the menu app — ✅ DONE
Rebuilt and relaunched during the driver-install window:
- `relevantDeviceUIDs` ignores `com.pancake.stage.aggregate`, so Stage start/stop doesn't blip the
  monitor — confirmed live: the log shows `devices changed: same set, ignoring` when Pancake Program
  appeared, instead of churning the aggregate.
- The DAW-button removal and the tolerant `Policy` Codable are now live.

### 5. Polish / robustness
- ✅ **Auto-tap when the target appears**: a HAL listener on `kAudioHardwarePropertyProcessObjectList`
  auto-taps the preferred app (Ableton) the moment it becomes tappable. One-shot — it disarms as soon
  as any app is chosen (here or from the menu), so it never overrides a later choice.
- ✅ **Mirror UX**: chrome-free window (no title bar/traffic-lights/shadow, title kept so Discord
  lists it), matches the display's exact aspect (no letterbox bars), lives on all Spaces (always on
  Discord's desktop), and is **always parked off-desktop** at a 1pt sliver — invisible but composited
  and shareable. No control panel: the Stage is `.accessory` (no Dock icon) and driven from the menu.
- ✅ **Lifecycle**: `StageAudio.stop`, the process listener and the file watcher are all torn down on
  terminate; the tap + aggregate always go with them.
- ⬜ **Multiple displays**: let the user pick which display to mirror (SCK lists them; today grabs first).
- ⬜ **Multiple apps in the program**: the aggregate already supports multiple taps; make the copy
  IOProc a sum and let the picker multi-select.
- ⬜ **Latency/perf**: fine for plugin-GUI iteration; sanity-check CPU/GPU during a long session.

---

## Suggested sequencing

1. ✅ **Redeploy the menu app** (#4) + a Screen share section that drives the Stage.
2. ✅ **`Pancake Program` device** (#1) + point StageAudio at it — the correctness fix.
3. ✅ **App picker** (#2) + auto-tap on appear (#5).
4. ✅ **Config via `stage.json` IPC** (#3, lighter form) — the menu is the control surface; the Stage
   is a faceless executor.
5. ✅ **Polish** (#5) — chrome-free always-parked mirror, faceless `.accessory` Stage, upright icon.
6. ⬜ **Remaining**: fold the program into `graph.json` proper (#3 full), multi-display, multi-app sum.

## Current repo state (for whoever picks this up)

- Committed and pushed to `origin/devel`: the whole system. `git log` has the details.
- The driver clone (adding `kObjectID_Device3`) was applied by a self-checking transform script that
  asserts each edit's match count — see `driver: add Pancake Program`. Cloning a *fourth* device
  would follow the same Device2/Device3 pattern.
- **Latent driver fixes not yet installed**: a code review (`driver: fix TranslateUIDToDevice +
  ControlList array refs`) corrected the plugin's own `kAudioPlugInPropertyTranslateUIDToDevice`
  (it omitted Device3 — harmless, clients use the system object's translate) and a dead ControlList
  copy-paste. The built driver has them; the *installed* one doesn't (`make check-driver` will
  differ). Latent-only; run `sudo make install-driver` at convenience.
- Stage lives in `Sources/PancakeStage` (`PancakeStage.swift` = app/video/config-watcher,
  `StageAudio.swift` = tap→Program sink, `main.swift` = entry). **One window** — the chrome-free
  **Pancake Stage** mirror, always parked off-desktop (1pt sliver), excluded from its own capture.
  It's a faceless `.accessory` app (no Dock icon, no control panel) driven from the menu bar via
  `~/.config/pancake/stage.json` (`StageConfig`/`StageStore` + shared `tappableApps()`, both in
  PancakeCore). Built with `make stage` / `make run-stage`; bundle id `com.pancake.stage`;
  `packaging/Stage-Info.plist`. To quit it: the menu's **Stop screen share**, or `make stop-stage`.
- The process-tap machinery (`ProcessTap`, tap support in `ChannelLayout`/`MatrixCompiler`/`Engine`,
  `Graph.setTap`/`.tap` nodes) is in PancakeCore and reused by Stage. It was briefly wired into the
  menu (a "Send DAW to Discord" button) and removed — that path mangled music through Discord's
  voice processing. The machinery stays; only the menu button went.
- TCC: apps sign with the "Pancake Dev" identity (Keychain). `make`'s `SIGN_ID` auto-detects it and
  falls back to ad-hoc elsewhere. Grants stick across rebuilds.
