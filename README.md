# 🥞 pancake

A macOS status bar item you click to pick your output device — backed by a real
routing engine, and expandable into a PipeWire-style graph when you want it.

Named for the fact that it's an audio **stack**. There was going to be a second
half to that pun involving panning, but panning turned out to be useless here, so
the name is now simply a name. Pancakes remain good.

## Why this exists

Loopback does all of this and more, but its per-monitor gain silently resets
itself — verified, see `NOTES.md`. That gain is internal Loopback state with no
CoreAudio surface, no AppleScript hook, and no preference controlling it, so it
cannot be pinned from outside the app. pancake designs the failure mode out: gains
are explicit, visible in the graph, and never written by the program.

The other reason is that `SwitchAudioSource` and a menu bar list would be a
weekend, but wouldn't get you a graph.

## Status

**Foundation laid (2026-09-11).** Builds and runs with Command Line Tools alone.

| Piece | State |
|---|---|
| `driver/` — `Pancake.driver`, two virtual devices | **installed and loaded** (ad-hoc signature is fine on 26.3) |
| `Sources/PancakeCore` — CoreAudio wrappers, graph model, engine | **daily-driver quality for output switching**: pinning, follow, hot-plug, mute-on-loss, Bluetooth reconnect |
| `Sources/pancake` — CLI: `devices`, `status`, `run`, `set-output`, `graph`, `probe-aggregate` | works |
| `Sources/PancakeApp` — menu bar app | **works** (audible end-to-end): output picker, status line, reconnect, log. Needs the Microphone grant it asks for at launch |
| process taps (per-app sources) | modelled in the graph, not wired into the engine |
| Pancake Mic (Discord feed) | device exists; nothing routes into it yet — needs graph links, no code |
| graph window | not started |

## Build

```sh
make build            # PancakeCore + the pancake CLI → .build/debug/pancake
make test             # unit tests
make driver           # driver/build/Pancake.driver
sudo make install-driver   # → /Library/Audio/Plug-Ins/HAL, restarts coreaudiod
make app              # build/Pancake.app — the menu bar app
make run-app          # launch it;  make stop-app quits it cleanly
```

No Xcode required, and there isn't one on this machine. `make test` passes the
flags Command Line Tools need to find swift-testing; plain `swift test` won't.

## Use it

`make run-app`. The menu bar item lists output devices; pick one. That's the product.

The first launch asks for **Microphone** access — allow it. Reading audio out of the
Pancake device is "microphone access" as far as macOS is concerned, and without it
the app routes silence with no error. Every `make app` re-signs the bundle, which
resets that grant, so expect the prompt again after a rebuild.

What it does while it sits there:

- **System output is pinned to `Pancake`**, so nothing can steal it. The engine
  routes Pancake to whatever you picked.
- **Control Center's output picker still works** — the engine follows it, routes
  there, and pins back. AirPods connecting routes to them automatically.
- **If your output vanishes** (AirPods to the phone), you get **silence**, not
  speakers. When audio starts playing again, the engine asks Bluetooth to bring
  the AirPods back, every 8 s, until they're listed. The menu also has a
  "Reconnect" item.
- **Volume keys** drive Pancake's own volume control. Nothing else ever touches a gain.
- **Quitting hands the default output back** to whatever it was feeding.

The graph file (`~/.config/pancake/graph.json`) is the source of truth: the CLI's
`pancake set-output <name>` and a text editor both change a running app's routing.
Log at `~/Library/Logs/pancake.log`.

The engine also runs without the app: `.build/debug/pancake run --output "MacBook Pro Speakers" --stats 5`.

## Layout

```
driver/            Pancake.driver — GPL-3.0 fork of BlackHole (see driver/README.md)
Sources/
  CPancakeRT/      the one IOProc + lock-free routing matrix, in C
  PancakeCore/
    CoreAudio/     typed property access, device snapshots, aggregate devices, HAL listeners
    Graph/         Node / Link / Graph, JSON persistence, file watcher
    Engine/        aggregate build/teardown, channel layout, matrix compiler, the engine
  pancake/         the CLI
  PancakeApp/      the menu bar app (SwiftUI MenuBarExtra; engine runs in-process)
packaging/         Info.plist for the .app bundle
Tests/             graph + matrix compiler tests, plus a live-HAL sanity test
tools/             standalone CoreAudio probes from the Loopback investigation
```

## Scope

**In:** virtual output device, graph-driven routing engine, menu bar output
switcher, per-app capture via process taps, hot-plug survival, a graph editor.

**Out:** plugin hosting, recording UI, anything resembling full Loopback parity.
If you need those, buy Loopback — it's good, and this isn't trying to replace it.

## Read next

- `DESIGN.md` — architecture, the graph model, the clock-drift decision, what's been learned
- `MIGRATION.md` — what has to be ripped out when Loopback goes, and in what order
- `NOTES.md` — what was measured about Loopback, and how
- `CLAUDE.md` — working notes for the next session (commands, gotchas)
