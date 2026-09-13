# pancake — TODO / parked ideas

Scoped but not built. See `CLAUDE.md` for operational notes and `DESIGN.md` for the audio model.

## Bus node + in-bus compressor — ✅ built (2026-09-13)

Shipped as sketched: `NodeKind.bus` (the one both-sides node), preallocated bus scratch in
`CPancakeRT`, a staged matrix (device routes → each bus in dependency order: compress, trim, then
its outgoing routes; bus→bus is a DAG, cycles are broken with a warning), `BusParams` stored beside
the links (a change hot-swaps the matrix like a gain), and a mid-canvas card with a compressor
toggle, live gain-reduction meter and a settings popover. See CLAUDE.md § Buses. What's *not* done:
an EQ (same shape as the compressor — a biquad or two per bus channel, in-cycle) if anyone wants it.

## Pancake left as the system default output with no engine — open

macOS keeps a ranked preferred-output list. pancake pins Pancake as the default all day, so Pancake
ranks first; if the real default disappears while pancake *isn't running* (AirPods walk away after a
crash or force-quit), macOS falls back to Pancake and nothing is audible. Quit hands the default back,
and quit can no longer hang (bounded at 4 s), but a crash or `kill -9` still leaves it. Options, none
built yet:

- **Driver-side (principled):** report `kAudioDevicePropertyDeviceCanBeDefaultDevice` true only while a
  client is reading Pancake (the engine's aggregate), with a few seconds of hysteresis so a rebuild's
  brief IO gap doesn't bounce the default, and notify the property change so coreaudiod re-evaluates.
  Needs measuring: does macOS actually move the default when it goes false? Does the hysteresis stop
  flapping (a notification storm is exactly what we must not create)?
- **App-side (partial):** on launch, if the default output is Pancake but the graph's hub output is a
  present physical device, that's the stale case — nothing to fix then, but log it; and keep the
  hand-back on every exit path we control (SIGTERM handler).

## Plugin (AU / VST3 / CLAP) inserts — declined for now; blast radius mapped

Still declined, but here's the anatomy so a future leg starts from analysis, not a cold read. Verdict:
**deep, not wide** — two new subsystems plus a wide-but-shallow sprinkle — and the real cost isn't
code, it's runtime robustness. AU first (first-party hosting); VST3/CLAP are their own SDKs on top.

### The one fact that shapes everything

`pk_ioproc` is pure C — no ObjC, no alloc, no locks (invariant #3). `AudioUnitRender` is ObjC, can
allocate, can lock. **So an AU physically cannot run inside the IOProc.** That forks the design:

- A **self-authored** effect (the compressor above) is C DSP → runs *in-cycle*, zero latency. Cheap.
- An **AU** must run *out-of-line*: the IOProc hands audio to another thread through a ring, that
  thread calls `AudioUnitRender`, and the result returns through a second ring a cycle+ later. It's
  the recorder ring (already built, `CPancakeRT`) but **bidirectional and on the hot path** — which
  drags in latency, a render thread, and "did the plugin keep up" glitches.

### It splits into two layers, and only Layer 2 is the nuke

**Layer 1 — mid-graph nodes (breaks bipartite).** An insert is both sink (in) and source (out), so it
needs a port on *both* sides. Wide-but-shallow, measured against the tree as of this writing:
- ~16 `isSource`/`isSink` sites (Graph, GraphEditorModel, GraphEditorView) that assume source XOR sink.
- ~15 `NodeKind` switches / ~40 case-arms that each want a plugin branch (mechanical, like adding
  `.recorder` was).
- ~10 editor spots hard-wired to *one port per side*: `GraphGeom.portCenter(isSource:)`, `PortDot`
  placing by `node.isSource`, `beginConnection(isSource:)`, `nearestNode(wantSource:)`, the
  sources-left/sinks-right `autoArrange`. Two ports on a node ⇒ connection + hit-testing + layout each
  need a real (not huge) rework.
- **This whole layer is now built** (the bus node): both-sides ports, per-side hit-testing, three-column
  layout. A plugin insert inherits it — only Layer 2 remains.

**Layer 2 — out-of-line AU hosting (the actual project).** Depth concentrates in two new places:
- **CPancakeRT**: per-insert in-ring + out-ring + route flags — the recorder ring generalized. Bounded.
- **A new AU-host module** (biggest single chunk, self-contained): `AudioComponent` discovery,
  `AUAudioUnit` instantiation, `allocateRenderResources`, a render thread pulling in-ring →
  `AudioUnitRender` → out-ring, interleaved↔deinterleaved conversion, and opening the AU's own view.
- Medium hooks: **MatrixCompiler** (a plugin contributes both sink *and* source slots) and **Engine**
  (instantiate/free AUs + spin/stop the render thread at rebuild — mirrors `syncRecorderSlots` + a thread).

### Where the complexity actually nukes (ongoing, not lines of code)

1. **Latency & PDC** — out-of-line adds delay + jitter; AUs report their own latency to compensate.
   Fine for a record/stream bus, bad for live monitoring.
2. **Format/variety** — mono-only, stereo-only, side-chains, odd layouts, sample-rate re-allocation.
3. **Third-party AUs crash** — in-process, a bad plugin takes down the IOProc → the user's audio. The
   robust answer is **out-of-process** hosting (AUv3 `.loadOutOfProcess`), which adds IPC. This is the
   single biggest reason it's a separate leg, not a feature.
4. **State/presets** — persist the AU's `fullState` into the graph or a sidecar.

### Rough scale + sequencing

~150 lines of C, a ~300–500-line AU host, ~30 small edits, moderate editor work — a few days to build,
then a long robustness tail. **Cheapest path to "insert an effect":** bus node → self-authored
compressor/EQ (both in-cycle, no latency, no crashes) covers ~80% of the want for a fraction of the
risk; the AU host is the remaining 20% that carries 80% of the pain. Licensing footnote: AU/AUv3 is
Apple first-party (fine); VST3 is GPLv3-or-proprietary (GPLv3 is compatible with this repo); CLAP is
MIT (fine).

## Self-tap safety — add a regression test

The engine now refuses to build a process tap for its own bundle ids (`Engine.selfBundleIDs`), and
`tappableApps()` hides them, because tapping the process that drives the IOProc caused runaway
feedback that bypassed the hub mute (found live 2026-09-12). Add a `PancakeCore` test asserting
`effectiveGraph` drops a `tap:com.pancake.app` node so this can never regress.
