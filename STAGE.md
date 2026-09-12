# Pancake Stage — design proposal (next leg)

*Written 2026-09-12, after the compositor concept was proven live in Discord.*

Read `DESIGN.md` for the audio architecture and `CLAUDE.md` for operational notes. This is the
plan for finishing **Pancake Stage**: the piece that lets you screen-share your whole desktop on
Discord with clean stereo app-audio and **no echo**.

---

## Status (updated 2026-09-12) — the core is DONE and verified live

The dedicated **Pancake Program** bus now exists and the Stage renders into it. Verified end to
end: with the Stage tapping Ableton, a probe read **Pancake Program at peaks ~1.0** (the program,
loud and clean) while **Pancake Mic read ~0.003** (dead silent — no bleed). Then a live Discord
window-share of the Stage got a **"green on both"**: friends heard Ableton clearly and *no* echo of
themselves. The v0 wart is gone.

- ✅ **#1 Pancake Program device** — added to the driver (`kObjectID_Device3`), installed, verified.
- ✅ **#2 App picker** — Stage lists tappable apps and renders whichever you pick, into Program.
- ✅ **#4 Menu app redeploy** — running the fresh build (ignores the stage aggregate; DAW button gone).
- ⬜ **#3 Graph integration** — still a proposal (below); do it when the graph editor work starts.
- ⬜ **#5 Polish** — remaining nice-to-haves (below); e.g. auto-tap when the target app appears.

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

### 3. Graph integration (config source-of-truth)
- **Why**: "what's in the program" should live in the graph (the `tap` nodes already exist), not be
  Stage-local — so it composes with the eventual graph editor.
- **What**: the Stage reads `~/.config/pancake/graph.json`, watches it, and taps whatever `tap`
  nodes route to a `Program` sink. This reuses `Graph`, `setTap`, `FileWatcher` from PancakeCore.
  The Stage becomes "render the graph's Program bus + mirror the screen."
- **Open question**: do the menu app (engine) and the Stage both create taps on the same app? Two
  taps is harmless but wasteful. Decide whether the Stage is the sole tap owner for the program.

### 4. Redeploy the menu app — ✅ DONE
Rebuilt and relaunched during the driver-install window:
- `relevantDeviceUIDs` ignores `com.pancake.stage.aggregate`, so Stage start/stop doesn't blip the
  monitor — confirmed live: the log shows `devices changed: same set, ignoring` when Pancake Program
  appeared, instead of churning the aggregate.
- The DAW-button removal and the tolerant `Policy` Codable are now live.

### 5. Polish / robustness (remaining)
- **Auto-tap when the target appears**: the picker refreshes on open (so an app that launched after
  the Stage still shows up), but you must re-pick it. If a preferred app (Ableton) launches *after*
  the Stage, auto-select/re-tap it. Watch `kAudioHardwarePropertyProcessObjectList`. (Hit live this
  session: Ableton opened after the Stage, so the launch-time auto-select missed it.)
- **Multiple displays**: let the user pick which display to mirror (SCK lists them; v0 grabs first).
- **Multiple apps in the program**: the aggregate already supports multiple taps; make the copy
  IOProc a sum and let the picker multi-select.
- **Mirror UX**: status now lives in the separate Controls window (not in the shared mirror). Nice
  next steps: a "you are sharing" affordance, cursor/retina checks (uses `display.width*2`).
- **Latency/perf**: fine for plugin-GUI iteration; sanity-check CPU/GPU during a long session.
- **Lifecycle**: quit cleanly (StageAudio.stop runs on terminate; app quits on last window close);
  make sure the tap + aggregate are always torn down.

---

## Suggested sequencing

1. ✅ **Redeploy the menu app** (#4).
2. ✅ **`Pancake Program` device** (#1) + point StageAudio at it — the correctness fix.
3. ✅ **App picker** (#2).
4. ⬜ **Graph integration** (#3) — when the graph editor work starts; taps become first-class program
   sources.
5. ⬜ **Polish** (#5) — as it annoys you; the top one is auto-tap when the target app appears.

## Current repo state (for whoever picks this up)

- Committed and pushed to `origin/devel`: the checkpoint of the whole system, the `Pancake Program`
  driver clone, and the Stage app-picker. `git log` has the details.
- The driver clone (adding `kObjectID_Device3`) was applied by a self-checking transform script that
  asserts each edit's match count — see the commit `driver: add Pancake Program`. Cloning a *fourth*
  device would follow the same Device2/Device3 pattern.
- Stage lives in `Sources/PancakeStage` (`PancakeStage.swift` = app/video/picker, `StageAudio.swift`
  = tap→Program sink, `main.swift` = entry). Two windows: the shared **Pancake Stage** mirror and a
  **Pancake Stage — Controls** window (picker + status, excluded from the capture). Built with
  `make stage` / `make run-stage`; bundle id `com.pancake.stage`; `packaging/Stage-Info.plist`.
- The process-tap machinery (`ProcessTap`, tap support in `ChannelLayout`/`MatrixCompiler`/`Engine`,
  `Graph.setTap`/`.tap` nodes) is in PancakeCore and reused by Stage. It was briefly wired into the
  menu (a "Send DAW to Discord" button) and removed — that path mangled music through Discord's
  voice processing. The machinery stays; only the menu button went.
- TCC: apps sign with the "Pancake Dev" identity (Keychain). `make`'s `SIGN_ID` auto-detects it and
  falls back to ad-hoc elsewhere. Grants stick across rebuilds.
