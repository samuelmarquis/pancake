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

## Compressor inside the bus — feasible, and unlike the plugin question

The plugin problem is "run someone else's render (ObjC/alloc/locks) inside the realtime callback."
A compressor **we write ourselves** is ~50 lines of C: envelope follower + gain curve +
attack/release smoothing, state per bus channel, applied to the bus buffer between the two stages.
No allocation, no locks, no Swift/ObjC — exactly the kind of DSP that's fine in the IOProc. So once
buses exist, the compressor is a small, safe addition (threshold / ratio / attack / release / makeup,
maybe soft knee). Expose the params on the bus node in the editor.

## Plugin (AU / VST3 / CLAP) inserts — declined for now

Would violate invariant #3 (the C IOProc must not call ObjC/Swift, allocate, or lock). Hosting a
plugin means calling its render inside that callback. The RT-safe path is a *separate* processing
graph (an `AVAudioEngine` side-chain, or an out-of-line render chain feeding a tap), not a contained
change. AU would be the easiest of the three (first-party hosting) when we do tackle it.

## Self-tap safety — add a regression test

The engine now refuses to build a process tap for its own bundle ids (`Engine.selfBundleIDs`), and
`tappableApps()` hides them, because tapping the process that drives the IOProc caused runaway
feedback that bypassed the hub mute (found live 2026-09-12). Add a `PancakeCore` test asserting
`effectiveGraph` drops a `tap:com.pancake.app` node so this can never regress.
