# pancake — design

Target: macOS 26.3 (Darwin 25.3), Apple Silicon.

## What it is

A status bar item you click to pick your output device — which expands into a
full routing graph when you want it.

Two tiers, deliberately:

- **Fast path (99% of use).** Click the menu bar icon, see a list of output
  devices, click one. Done in under a second, no window, no thinking.
- **Deep path.** Open the full window: a PipeWire-style node graph of sources,
  sinks and links, wired by hand.

The fast path is the product. The graph is the thing that makes it worth building
your own instead of using `SwitchAudioSource`.

## The shape of it

```
  apps ──▶ process taps ─┐
                         │
  apps ──▶ "Pancake" ────┼──▶  ┌──────────────────┐
           virtual dev   │     │  pancake-engine  │
                         │     │  graph → matrix  │──▶ AirPods
  physical inputs ───────┘     │  one IOProc      │──▶ speakers
                               └──────────────────┘──▶ …
                                        ▲
                               ┌────────┴────────┐
                               │  menu bar UI    │  fast path
                               │  graph window   │  deep path
                               └─────────────────┘
```

Three pieces: a driver, an engine, a UI. The driver is a solved problem, the
engine holds all the risk, and the UI is where the time actually goes once the
engine works.

---

## 1. `PancakeDevice.driver` — the virtual device

An `AudioServerPlugIn` bundle loaded by `coreaudiod`. A loopback device: output
streams apps write into, input streams that read the same frames back through a
ring buffer. `DoIOOperation` handles `kAudioServerPlugInIOOperationWriteMix` and
`kAudioServerPlugInIOOperationReadInput`.

**Don't write this from scratch.** BlackHole (MIT, Existential Audio) is exactly
this in ~2–3k lines of C. Fork it, rename bundle ID / device name / UID, cut the
channel-count variants to stereo.

### It must expose a volume control

`kAudioDevicePropertyVolumeScalar`, output scope, settable, applied once in
`DoIOOperation`. Deliberate and load-bearing: **Pancake is the system output
device, so this is what the volume keys drive, and it's what stands between a bad
graph and your eardrums.** Never hardwire it to unity.

---

## 2. `pancake-engine` — the graph

### Model the graph from day one

Even while the only UI is "pick an output," the engine should be graph-driven.
The menu bar then just manipulates a trivial two-node graph. Retrofitting a graph
engine onto a hardcoded single-route engine later is genuinely painful, and this
costs almost nothing up front.

```
Node  = ProcessTap(pid, bundleID)     // per-app capture, macOS 14.4+
      | DeviceInput(uid)              // physical input
      | VirtualOut                    // what apps wrote to Pancake
      | DeviceOutput(uid)             // physical output
      | VirtualIn                     // what apps can record from Pancake

Link  = { from: (Node, channel), to: (Node, channel), gain: Float }
```

"Select output device" is then: drop every `Link` out of `VirtualOut`, add
`VirtualOut[L,R] → DeviceOutput(chosen)[L,R]` at unity. One code path, whether it
was driven by a menu click or by dragging a cable.

### The hard problem: clock drift

The obvious implementation is wrong. Opening each device with its own IOProc and
passing frames through ring buffers gives you **independent clocks** — the
AirPods' real rate is not exactly 48 kHz, the buffers monotonically drain or
overflow, and you get clicks and then dropouts. Fixing that properly needs an
asynchronous sample-rate converter with a drift-estimating feedback loop. That is
where a naive version of this project dies.

**Let CoreAudio do it.** Build one private aggregate device containing every
device the graph touches, and let the HAL resample them into a common timeline:

```
AudioHardwareCreateAggregateDevice({
    kAudioAggregateDeviceUIDKey:           "com.pancake.aggregate",
    kAudioAggregateDeviceIsPrivateKey:     1,            // hidden from Sound settings
    kAudioAggregateDeviceSubDeviceListKey: [pancakeUID, …every device in graph…],
    kAudioAggregateDeviceMainSubDeviceKey: primaryOutputUID,   // real hw is clock master
    kAudioAggregateDeviceTapListKey:       [ …process taps… ],
})
```

Set `kAudioSubDevicePropertyDriftCompensation = 1` on every sub-device **except**
the master. (The main/master key was renamed across SDKs — older headers spell it
`kAudioAggregateDeviceMasterSubDeviceKey`.)

Then install **one** `AudioDeviceCreateIOProcID` on the aggregate. Every node
appears in a single callback in one clock domain, and the inner loop is just the
link matrix applied over buffers. No ring buffers, no ASRC, no drift logic of
your own.

**This single decision is the difference between a weekend and a month**, and it
is also what makes the graph tractable at all — an arbitrary graph across N
devices stays one callback.

### Per-app sources

macOS 14.4+ gives `AudioHardwareCreateProcessTap(CATapDescription*, …)` — public
API, no code injection. This is the thing Rogue Amoeba spent years building ACE
to do, and it's now free. Taps go straight into the aggregate's
`kAudioAggregateDeviceTapListKey` (each as `kAudioSubTapUIDKey`), so a tapped app
is just another set of input channels in the same IOProc.

Requires TCC consent — "System Audio Recording Only" — which is a real permission
prompt.

### Hot-plug

Where the real bugs will be, not in the DSP. Listen on
`kAudioHardwarePropertyDevices`. On change: prune links referencing departed
devices, rebuild the aggregate, restart the IOProc. Rebuild rather than mutating a
live aggregate. Serialize all teardown/rebuild onto one queue from the very
beginning — device callbacks arrive on arbitrary threads while the IOProc runs,
and retrofitting that serialization later is miserable.

Budget real time here. AirPods vanishing mid-stream, wake from sleep, and sample
rate renegotiation are what will actually bite.

---

## 3. UI

### Menu bar (the product)

SwiftUI `MenuBarExtra`. Click → list of output devices, current one checked,
click to switch. That's it. Should feel instant; it's a graph mutation and an
aggregate rebuild, nothing more.

### Graph window (the reason to build it)

Opens from the menu. Nodes for apps / devices / the virtual device, ports for
channels, bezier links you drag. Per-link gain lives here and nowhere else.

SwiftUI `Canvas` plus draggable node views is enough — this doesn't need a graph
framework. Persist to `~/.config/pancake/graph.toml`, human-editable and
version-controllable, so it can be managed from home-manager with everything else.

**Be honest that this half is where scope dies.** The engine is a bounded problem;
a graph editor is not. Ship the menu bar first and live on it for a while.

---

## Gain

The Loopback bug was not "a gain control existed." It was that the gain was
*implicit*, *per-device*, and *silently mutated* — reset to ~50% at unpredictable
times with no affordance saying it was even stateful. See `NOTES.md`.

So the rule:

> Every gain in pancake is explicit, visible in the graph, and never written by
> the program.

| Stage | Where | Who sets it |
|---|---|---|
| Device volume | driver | volume keys, live |
| Link gain | graph | you, in the UI or the config — defaults to unity |
| Physical device hardware volume | — | **nobody. pancake never writes it.** |

Links default to unity and stay there unless explicitly changed. Nothing in the
program ever adjusts a gain on its own.

---

## Milestones

| # | Deliverable | Rough effort |
|---|---|---|
| M0 | CoreAudio probes — **done**, see `tools/` | — |
| M1 | Fork BlackHole → stereo "Pancake" device loads, appears in Sound settings | 1–3 days, mostly signing |
| M2 | Graph model + engine: aggregate, drift comp, one IOProc, hardcoded 2-node graph | 3–5 days |
| M3 | Hot-plug survives connect / disconnect / sleep without a restart | 3–5 days ← the real work |
| M4 | Menu bar output switcher + config + launchd agent | 2–3 days |
| M5 | Process taps as graph sources | 3–5 days |
| M6 | Graph window | open-ended — scope carefully |

M1–M4 is a tool worth using daily, and supersedes the `audio-defaults` agent —
pinning the system output becomes unnecessary once it points at a device that
never disappears.

## Risks

- **Driver signing.** `coreaudiod` is picky about HAL plug-ins. Budget a day of
  pure frustration and don't be surprised.
- **Hot-plug races.** See above. Serialize from day one.
- **Sample-rate mismatch.** Pin the aggregate to the master's nominal rate,
  rebuild on change, don't be clever.
- **Graph scope creep.** M6 has no natural end. Timebox it.

## Prior art

- **BlackHole** (MIT) — the virtual device, essentially verbatim for M1
- **Background Music** (GPL) — per-app volume + virtual device, good architecture read
- **AudioCap** (Guilherme Rambo) — process taps worked end-to-end, for M5

## When not to build this

If all you want is "system audio goes to the device I pick," you don't need a
virtual device — just switch the default output. The virtual device earns its keep
because it keeps the system output stable across physical-device changes and gives
the graph one stable hub to route around.
