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

**Don't write this from scratch.** BlackHole (Existential Audio) is exactly this
in ~4.6k lines of C. **It is GPL-3.0, not MIT** — fine for a personal tool, and the
driver sits behind a process boundary (it runs inside `coreaudiod`; the engine only
talks HAL to it), so `Sources/` stays unencumbered. Forked as `driver/Pancake.c`.

### Four devices, not one

The Discord case ("they should hear Ableton, not themselves") needs a virtual
*microphone* whose content the graph decides — not a mirror of the system output.
So the driver exposes independent loopback devices — four of them by now:

| Device | UID | Graph role |
|---|---|---|
| **Pancake** | `Pancake_UID` | `hub` — apps play here, the engine reads it. System default output. |
| **Pancake Mic** | `PancakeMic_UID` | `mic` — the engine writes here, apps record from it. |
| **Pancake Program** | `PancakeProgram_UID` | `program` — the engine writes here; the Stage plays it back as its own output, which is what a window-share of the Stage carries. |
| **Pancake Stage** | `PancakeStage_UID` | (not in the graph) the Stage's private render target, so its playback of Program isn't fed back into Program. |

BlackHole already has a second device ("Mirror"), but it shares the first one's
ring buffer. The fork gives each device its own; that's the one substantive change.
Program and Stage came later, for screen-share, and are the same clone again.

Why doesn't the Stage capture the shared app itself? It did at first. But a Core
Audio process tap is exclusive in practice: two taps on the same app fight and one
goes silent, so the moment the graph also tapped that app (into a recorder, or the
mic) the stream went quiet. One owner for every tap — the engine — and the Stage
reduced to a repeater is the only arrangement where "share it *and* record it *and*
send it to Discord's mic" is just three wires from one node.

### It must expose a volume control — on Pancake only

`kAudioDevicePropertyVolumeScalar`, output scope, settable, applied once in
`DoIOOperation`. Deliberate and load-bearing: **Pancake is the system output
device, so this is what the volume keys drive, and it's what stands between a bad
graph and your eardrums.** Never hardwire it to unity.

**Pancake Mic has no controls at all**, and neither device has input-scope
controls. Upstream shares one volume value across every control object, so a
volume-key press would otherwise attenuate the Discord feed too.

---

## 2. `pancake-engine` — the graph

### Model the graph from day one

Even while the only UI is "pick an output," the engine should be graph-driven.
The menu bar then just manipulates a trivial two-node graph. Retrofitting a graph
engine onto a hardcoded single-route engine later is genuinely painful, and this
costs almost nothing up front.

```
Node  = hub                           // "Pancake": what apps played (source)
      | mic                           // "Pancake Mic": what apps can record (sink)
      | input(deviceUID)              // physical input (source)
      | output(deviceUID)             // physical output (sink)
      | tap(bundleID)                 // per-app capture, macOS 14.2+ (source)
      | program                       // "Pancake Program": the screen-share bus (sink)
      | recorder(id)                  // capture-to-disk (sink; not a device)
      | bus(id)                       // summing bus: sink *and* source; compressor + trim on the sum

Link  = { from: (Node, channel), to: (Node, channel), gain: Float = 1 }
```

"Select output device" is then `Graph.setOutput(uid:)`: drop the hub's links to
output nodes, add `hub[L,R] → output(chosen)[L,R]` at unity, leave everything else
(mic mixes, taps) alone. One code path, whether it was driven by a menu click, the
CLI, or dragging a cable. The graph is the *desired* state and may reference
unplugged devices; the engine derives an *effective* graph from it on every
rebuild (absent devices dropped, a fallback output added if the hub would
otherwise be silent).

**The graph file is the IPC.** `~/.config/pancake/graph.json`, watched by the
running engine. The menu bar, the CLI and a text editor all just write it. Keeps
the daemon dumb and the config a plain, version-controllable file.

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

Ask for drift compensation on every sub-device **except** the master via
`kAudioSubDeviceDriftCompensationKey` in the composition. (Reading it back on the
sub-devices doesn't work on macOS 26 — `ActiveSubDeviceList` returns plain device
IDs, which answer `'who?'` to `kAudioSubDeviceProperty*`.) The main/master key was
renamed across SDKs — older headers spell it `kAudioAggregateDeviceMasterSubDeviceKey`.

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
and retrofitting that serialization later is miserable. (`Engine` does exactly
this: one `DispatchQueue`, every state mutation on it, debounced rebuilds.)

**Learned the hard way:** a private aggregate is visible to the process that
created it, and creating or destroying one fires `kAudioHardwarePropertyDevices`
*to you*. Rebuild on every notification and you rebuild forever. The engine
snapshots the set of device UIDs (minus its own aggregate) at each rebuild and
ignores notifications that don't change it.

### Follow the default output

macOS moves the default output device around on its own — to AirPods when they
connect, back to the speakers when they leave — and that churn is exactly the
problem. pancake turns it into a feature: the engine
listens for default-output changes, and when the new default is a *physical*
output it routes `hub → that device` and pins the default back to the hub. The
result is that Control Center's output picker *is* pancake's picker, and AirPods
connecting routes audio to them without anyone touching anything. Virtual
devices (e.g. `Loopback Audio`, set by the old agent) are never followed.

Budget real time here. AirPods vanishing mid-stream, wake from sleep, and sample
rate renegotiation are what will actually bite. Two things that were open are now
settled on this machine:

- Headset-mode drop: **doesn't happen.** macOS 26 lists the AirPods as two
  devices, `…:input` (24 kHz mono) and `…:output` (48 kHz stereo); only `:output`
  goes in the aggregate and it stays at 48 kHz.
- Theft: **a running IOProc does not stop the phone taking them.** What pancake
  can do is mute instead of falling back to speakers, and ask Bluetooth for them
  back when audio resumes here.
- And a third, found the expensive way: the app reading zeros from the hub was
  never the aggregate or the driver — it was a missing Microphone grant. TCC
  hands a denied client silence, not an error. `CLAUDE.md` § App notes.

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
framework. Persist to `~/.config/pancake/graph.json`, human-editable and
version-controllable.

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
| Physical device hardware volume | engine | **held at unity while pancake routes to it** — see below |

Links default to unity and stay there unless explicitly changed. Nothing in the
program ever adjusts a gain on its own.

**The one exception, and why (2026-09-11).** The original rule was "pancake never
writes a physical device's volume". Then the AirPods came back from the phone with
their own hardware volume at 0.5. With Pancake as the default output the volume
keys drive Pancake's control, so that gain is invisible — exactly the silent,
stateful, per-device gain this project exists to kill, just with iOS as the culprit
instead of Loopback. So: while a physical device is the hub's routed output, the
engine holds its hardware volume at unity, re-asserts it if anything else changes
it, restores the previous value when it stops routing there, and logs every write.
The audible volume is then exactly Pancake's slider, always. On quit the device is
left at Pancake's level rather than the saved one, so handing the system output
back never changes what you hear.

Known trade-off: an on-device volume gesture (an AirPods stem swipe) writes that
same hardware volume, so while pancake holds it the gesture is undone within a
tick and logged as `something set … re-asserted unity`. If that turns out to
matter, the fix is to mirror the gesture into Pancake's own volume instead of
fighting it — the same log line is where you'd find out.

**The hold must never be a loop (2026-09-22).** Answering every change notification
is how you get a write war: AirPods connect, macOS restores the level it remembers
for them, our unity write provokes another restore, and so on — measured **2361
volume writes in 32 seconds**, during which the IOProc was writing real audio into
headphones that played *nothing*, after which they dropped off Bluetooth entirely.
A volume write to a Bluetooth device is an AVRCP command sharing the link with the
audio; flood it and there's no audio left. So the hold is bounded: changes collapse
into one deferred write (0.75 s), and four re-asserts inside 30 s means something
else owns this device's volume — pancake stops pushing, logs it, and tries once
more a minute later. Losing the hold costs a quieter device; winning it by force
costs the audio.

---

## Milestones

| # | Deliverable | Rough effort |
|---|---|---|
| M0 | CoreAudio probes — **done**, see `tools/` | — |
| M1 | Fork BlackHole → "Pancake" + "Pancake Mic" — **built, not yet installed** (`sudo make install-driver`) | signing turned out to be ad-hoc `codesign -s -` |
| M2 | Graph model + engine: aggregate, drift comp, one IOProc — **done**, verified against Loopback Audio as hub | — |
| M3 | Hot-plug survives connect / disconnect / sleep without a restart — engine rebuilds on device changes; **unproven against real AirPods** | ← the real work |
| M4 | Menu bar output switcher + launchd agent — config file and CLI exist; no UI | 2–3 days |
| M5 | Process taps as graph sources — `tap` node exists in the model; engine skips it | 3–5 days |
| M6 | Graph window | open-ended — scope carefully |

M1–M4 is a tool worth using daily: pinning the system output becomes unnecessary
once it points at a device that never disappears.

**Watch out for anything else that pins the default output.** If some other tool
(a login agent, another virtual-audio app on a timer) keeps re-asserting the
system default output, it will fight pancake throughout bring-up and present as
"pancake doesn't work." Disable it first.

## Risks

- **Driver signing.** `coreaudiod` is picky about HAL plug-ins. The bundle is
  ad-hoc signed (no Developer ID on this machine); whether `coreaudiod` on macOS
  26.3 loads it is the first thing to find out at install time.
- **Hot-plug races.** See above. Serialize from day one.
- **Sample-rate mismatch.** Pin the aggregate to the master's nominal rate,
  rebuild on change, don't be clever.
- **Graph scope creep.** M6 has no natural end. Timebox it.

## Prior art

- **BlackHole** (GPL-3.0) — the virtual device; `driver/` is a fork
- **Background Music** (GPL) — per-app volume + virtual device, good architecture read
- **AudioCap** (Guilherme Rambo) — process taps worked end-to-end, for M5

## When not to build this

If all you want is "system audio goes to the device I pick," you don't need a
virtual device — just switch the default output. The virtual device earns its keep
because it keeps the system output stable across physical-device changes and gives
the graph one stable hub to route around.
