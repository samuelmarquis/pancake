# pancake — TODO / parked ideas

Scoped but not built. See `CLAUDE.md` for operational notes and `DESIGN.md` for the audio model.

## Bus node (summing bus) — feasible, not a model-annihilator

A graph node with an arbitrary number of inputs (the editor always shows one empty input past the
connected ones) and one output. Because the matrix already sums (`out += in*gain`), a bus only earns
its keep when you need something direct fan-in can't give: **(a)** one master gain over a group,
**(b)** processing on the sum, **(c)** the mix computed once and fanned to several destinations.

All three need an **intermediate mix buffer**, which the RT context doesn't have today (it only holds
the aggregate's device buffers). The change, bounded and coherent:

- **CPancakeRT**: pre-allocated bus scratch buffers (allocated at rebuild, never in the IOProc) + a
  two-stage pass — clear buses, sum `in→bus`, *process*, then route `bus→out`. Still C, no
  alloc/locks in the callback (invariant #3 holds). Keep it one bus layer (no bus→bus) to avoid
  topological ordering, or precompute an order for a DAG.
- **Graph**: a `bus` node kind that is *both* source and sink — the one node with ports on both
  sides. This is the "break bipartite" bit, but cleanly (bus sits mid-canvas, inputs left, output right).
- **MatrixCompiler / Engine**: emit two-stage routes; carry per-bus params.
- **Editor**: a mid-canvas node whose input count grows as you wire it (always one spare input).

This bus node *is* "Layer 1" of the plugin work below (mid-graph both-sides nodes) — see the blast-radius
notes there. Building the bus first means the plugin inherits the whole bipartite-break for free.

## Compressor inside the bus — feasible, and unlike the plugin question

The plugin problem is "run someone else's render (ObjC/alloc/locks) inside the realtime callback."
A compressor **we write ourselves** is ~50 lines of C: envelope follower + gain curve +
attack/release smoothing, state per bus channel, applied to the bus buffer between the two stages.
No allocation, no locks, no Swift/ObjC — exactly the kind of DSP that's fine in the IOProc. So once
buses exist, the compressor is a small, safe addition (threshold / ratio / attack / release / makeup,
maybe soft knee). Expose the params on the bus node in the editor.

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
- **This whole layer is shared with the bus node above.** Build the bus first and the plugin inherits it.

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
