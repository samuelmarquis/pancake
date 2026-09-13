# 🥞 pancake

A macOS menu-bar audio router. Click the menu-bar icon to pick your output
device — or open the graph and wire your audio however you like: apps → speakers,
a microphone → Discord, one app's audio → a screen share, all at once, with
per-connection gain you can actually see.

Named for the fact that it's an audio **stack**. There was going to be a second
half to that pun involving panning, but panning turned out to be useless here, so
the name is now simply a name. Pancakes remain good.

## Why this exists

Loopback does most of this and more, but its per-monitor gain silently resets
itself (measured — see `NOTES.md`), and that gain is internal Loopback state with
no CoreAudio surface, no AppleScript hook, and no preference controlling it, so it
can't be pinned from outside the app. pancake designs the failure mode out: gains
are **explicit, visible in the graph, and never written by the program** — only by
you. The routing engine underneath is a real one (an aggregate device with a
lock-free C mixing matrix), so once it's wired it just runs.

It's also a menu-bar output switcher that survives the things that usually break
them: AirPods stolen by your phone, hot-plugged interfaces, Control Center
switching output out from under you.

## What it does

pancake installs four virtual audio devices and routes between them and your real
hardware:

| Device | What it's for |
|---|---|
| **Pancake** | The system output. Apps play here; it carries the volume control (the volume keys drive it). |
| **Pancake Mic** | A virtual input. Wire real mics and app audio into it; Discord/Zoom/etc. record it. |
| **Pancake Program** | The screen-share bus. Wire anything into it — one app, several, your mic — and that mix is what a window-share of the Stage carries. |
| **Pancake Stage** | The Stage's private render target (it plays Program back as its own output). You never touch it. |

From the menu bar you get: an output picker (Control Center's picker works too —
the engine follows it), a volume slider, input selection for Pancake Mic, output/
input locks, "Reconnect" for stolen Bluetooth, screen-share start/stop, and
**Start at login**.

### The graph

**Show graph…** opens a PipeWire-style patchbay:

- **Sources** on the left (Pancake, real inputs, per-app process taps), **sinks**
  on the right (real outputs, Pancake Mic, Pancake Program). Drag between ports to
  route; drag a wire that already exists to remove it.
- **Stereo/mono is fungible** — one bus port per node, drawn as bundled strands;
  the channel mapping (mono fans to both, stereo sums to mono) is chosen for you.
- **Wires blend colour** from the source node's hue to the sink's. Live links are
  solid; links waiting on an absent device are dashed.
- **Gain is a knob on the wire** — hover a wire, a ring-gauge knob appears at its
  midpoint; drag to set gain, double-click for unity. `⌫` or right-click → Remove
  deletes a wire; nodes get a hover ✕.
- **Add nodes** from the top bar or by right-clicking the canvas (drops at the
  cursor). Drag nodes around; **Tidy** snaps them to the grid.
- **Screen share is part of the graph**: wire an app's tap → **Pancake Program**
  and the helper streams that app — or wire several apps, or your mic, each with
  its own knob; the engine mixes them. One app can feed the stream, a recorder and
  Discord's mic at once from a single tap. (Verified live: a Discord window-share
  of one app's audio, friends heard it clearly, no echo.)
- **Record anything to disk**: add a **Recorder** node and wire any source(s)
  into it — it has a record/stop button, a live timer, and a folder button to
  pick where the take lands (defaults to a timestamped `.wav` in `~/Music/Pancake`).
  Capture is realtime-safe: the mix goes into a lock-free ring the callback only
  `memcpy`s into, and a background thread writes the file.

Node positions live in `~/.config/pancake/graph-layout.json`; the routing itself
is `~/.config/pancake/graph.json`, which is the source of truth — the menu, the
graph editor, the CLI, and a text editor all just write that file, and the running
engine picks the change up.

## Requirements

- **Apple Silicon Mac**, built and run on **macOS 26.3**. Per-app capture uses
  CoreAudio process taps (macOS 14.2+).
- **Command Line Tools** only — no Xcode, no paid signing identity. Everything is
  built with `swift build` + `clang` and ad-hoc signed.
- The app asks for **Microphone** access on first launch — allow it. Reading audio
  out of the Pancake device is "microphone access" as far as macOS is concerned,
  and without it the app routes silence with no error.

## Build & install

```sh
make driver                 # → driver/build/Pancake.driver
sudo make install-driver    # → /Library/Audio/Plug-Ins/HAL, restarts coreaudiod (needs your password)
make app                    # → build/Pancake.app (the menu-bar app)
make stage                  # → build/PancakeStage.app (the screen-share helper)
make install-app            # copies both to ~/Applications (stable paths, no sudo)
open ~/Applications/Pancake.app
```

Then use the menu's **Start at login** if you want it always on. Installing the
driver restarts `coreaudiod`, which drops every audio stream on the machine for
about a second; apps reconnect on their own.

There's also a CLI for scripting and debugging:

```sh
make build                  # → .build/debug/pancake
.build/debug/pancake status | devices [--all] | graph | set-output <name>
.build/debug/pancake run --output "MacBook Pro Speakers" --stats 5   # engine without the app
.build/debug/pancake record --source hub --seconds 10                # record to ~/Music/Pancake
make test                   # unit tests (passes the flags CLT needs for swift-testing)
```

## Layout

```
driver/            Pancake.driver — GPL-3.0 fork of BlackHole (see driver/README.md)
Sources/
  CPancakeRT/      the one IOProc + lock-free routing matrix, in C
  PancakeCore/
    CoreAudio/     typed property access, device snapshots, aggregate devices, HAL listeners
    Graph/         Node / Link / Graph, JSON persistence, file watcher
    Engine/        aggregate build/teardown, channel layout, matrix compiler, the engine
    Stage/         tappable-app discovery (shared by the menu and the graph palette)
  pancake/         the CLI
  PancakeApp/      the menu-bar app + the graph editor (SwiftUI)
  PancakeStage/    the faceless screen-share helper
packaging/         Info.plist for the .app bundles
Tests/             graph + matrix-compiler tests, plus a live-HAL sanity test
tools/             standalone CoreAudio probes
```

## Scope

**In:** four virtual devices, a graph-driven routing engine, a menu-bar output
switcher, per-app capture via process taps, single-app screen-share audio,
recording to disk, hot-plug/Bluetooth survival, and the visual graph editor.

**Out:** plugin (AU/VST/CLAP) inserts — the C IOProc is pure `out += in*gain` with
no allocation or locks, and hosting a plugin means calling its render inside that
callback (a separate project; see `DESIGN.md` and `TODO.md`). Also out: a
recording UI, and full Loopback parity. If you need those, buy Loopback — it's
good, and this isn't trying to replace it.

## Licence

pancake is **GPL-3.0** — see `LICENSE`. The HAL driver under `driver/` is a fork
of [BlackHole](https://github.com/ExistentialAudio/BlackHole) (© Existential Audio
Inc.), also GPL-3.0; see `driver/LICENSE`. The Swift app, CLI and engine share no
code with the driver — they talk to it only across the CoreAudio process boundary.
The BlackHole name and branding belong to Existential Audio and aren't used by
pancake's devices.

## Read next

- `DESIGN.md` — architecture, the graph model, the clock-drift decision, what's been learned
- `NOTES.md` — what was measured about Loopback's volume behaviour, and how
- `CLAUDE.md` — operational notes (commands, invariants, gotchas)
- `TODO.md` — scoped-but-unbuilt ideas (summing-bus node, in-bus compressor)
```
