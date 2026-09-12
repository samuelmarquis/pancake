# Pancake Stage — design proposal (next leg)

*Written 2026-09-12, after the compositor concept was proven live in Discord.*

Read `DESIGN.md` for the audio architecture and `CLAUDE.md` for operational notes. This is the
plan for finishing **Pancake Stage**: the piece that lets you screen-share your whole desktop on
Discord with clean stereo app-audio and **no echo**.

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

### The v0 wart to fix
The Stage renders into **Pancake Mic**, which is also Discord's *voice* input. So the program
(Ableton) bleeds into the voice channel — mono, voice-processed — underneath the clean stream. It's
masked in practice, but it's wrong. The fix is a dedicated silent sink (below).

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

### 1. `Pancake Program` — a silent sink device (driver)
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

### 2. App picker in Stage (stop hardcoding Ableton)
- **Why**: you should choose what to share; Ableton is just today's default.
- **What**: a small control in the Stage window (an `NSPopUpButton` or a menu) listing tappable
  apps (`ProcessTap.processes()` ∩ regular running apps, the logic drafted in the removed AppModel
  code — recover from git/scratchpad). Selecting one restarts `StageAudio` on that bundle id.
- **Stretch**: share **multiple** apps (Ableton + a browser for reference tracks) — the aggregate
  already supports multiple taps; the copy IOProc becomes a sum.

### 3. Graph integration (config source-of-truth)
- **Why**: "what's in the program" should live in the graph (the `tap` nodes already exist), not be
  Stage-local — so it composes with the eventual graph editor.
- **What**: the Stage reads `~/.config/pancake/graph.json`, watches it, and taps whatever `tap`
  nodes route to a `Program` sink. This reuses `Graph`, `setTap`, `FileWatcher` from PancakeCore.
  The Stage becomes "render the graph's Program bus + mirror the screen."
- **Open question**: do the menu app (engine) and the Stage both create taps on the same app? Two
  taps is harmless but wasteful. Decide whether the Stage is the sole tap owner for the program.

### 4. Redeploy the menu app (pending, already coded)
The running menu app is a build or two behind. Code already written but **not deployed**:
- `relevantDeviceUIDs` now ignores `com.pancake.stage.aggregate` (so Stage start/stop doesn't blip
  the monitor). **Needs a `make app` + relaunch to take effect.**
- The DAW-button removal (menu + AppModel) and the tolerant `Policy` Codable are in the source but
  the live app predates them.
- Do this at a convenient moment (relaunch briefly drops monitor audio).

### 5. Polish / robustness
- **Multiple displays**: let the user pick which display to mirror (SCK lists them; v0 grabs the
  first).
- **Ableton not running / restarts**: v0 taps once at launch. Watch the HAL process list
  (`kAudioHardwarePropertyProcessObjectList`) and (re)create the tap when the target app appears.
- **Mirror UX**: the status strip is bring-up scaffolding; replace with a clean overlay (or hide it
  during share). Consider a subtle "you are sharing" affordance. Check cursor rendering and
  retina/resolution (v0 uses `display.width*2`).
- **Latency/perf**: fine for plugin-GUI iteration; sanity-check CPU/GPU during a long session.
- **Lifecycle**: quit cleanly (StageAudio.stop already runs on terminate); make sure the tap +
  aggregate are always torn down.

---

## Suggested sequencing

1. **Redeploy the menu app** (#4) at a good moment — cheap, removes the Stage-start blip, ships the
   already-written cleanups.
2. **`Pancake Program` device** (#1) + point StageAudio at it — kills the voice bleed. This is the
   correctness fix; do it before leaning on Stage day-to-day.
3. **App picker** (#2) — makes Stage generally useful.
4. **Graph integration** (#3) — when the graph editor work starts; taps become first-class program
   sources.
5. **Polish** (#5) — as it annoys you.

## Current repo state (for whoever picks this up)

- Nothing is committed yet this session — `git status` shows the whole `Sources/`, `driver/`, etc.
  as new/modified. A commit checkpoint before the next leg would be wise.
- Stage lives in `Sources/PancakeStage` (`PancakeStage.swift` = app/video, `StageAudio.swift` =
  tap→sink, `main.swift` = entry). Built with `make stage` / `make run-stage`; bundle id
  `com.pancake.stage`; Info.plist at `packaging/Stage-Info.plist` (declares Microphone).
- The process-tap machinery (`ProcessTap`, tap support in `ChannelLayout`/`MatrixCompiler`/`Engine`,
  `Graph.setTap`/`.tap` nodes) is in PancakeCore and reused by Stage. It was briefly wired into the
  menu (a "Send DAW to Discord" button) and removed — that path mangled music through Discord's
  voice processing. The machinery stays; only the menu button went.
- TCC: apps sign with the "Pancake Dev" identity (Keychain). `make`'s `SIGN_ID` auto-detects it and
  falls back to ad-hoc elsewhere. Grants stick across rebuilds.
