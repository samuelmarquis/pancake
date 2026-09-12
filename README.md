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

Design sketch. Nothing implemented. `tools/` holds working CoreAudio probes used
to reverse-engineer the problem — those run today.

## Scope

**In:** virtual output device, graph-driven routing engine, menu bar output
switcher, per-app capture via process taps, hot-plug survival, a graph editor.

**Out:** plugin hosting, recording UI, anything resembling full Loopback parity.
If you need those, buy Loopback — it's good, and this isn't trying to replace it.

## Read next

- `DESIGN.md` — architecture, the graph model, and the one hard problem (clock drift)
- `NOTES.md` — what was measured about Loopback, and how
