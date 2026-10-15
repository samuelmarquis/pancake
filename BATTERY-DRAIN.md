# Pancake idle battery drain — 2026-10-13

## Decision

Reopen `CLAUDE.md` next-step item 7, **“Idle the IO in silence.”** The trigger recorded there has now happened: a battery complaint, with Pancake's always-running aggregate measured at the previously documented worst-case idle cost.

Pancake is essential and should remain launch-at-login. Quitting it is not a viable long-term mitigation. The engine needs an idle state that stops aggregate IO while no external client needs Pancake, then wakes when audio activity appears.

## Live evidence

Measured on macOS 26.3 / Apple Silicon while the machine was otherwise being investigated for rapid battery loss:

- Battery health was normal: 96% maximum capacity, 186 cycles, no thermal warning.
- Pancake had been running for about two days.
- `coreaudiod` held `PreventUserIdleSystemSleep` for Pancake's aggregate:

  ```text
  com.apple.audio.com.pancake.engine.aggregate.context.preventuseridlesleep
  Created for PID: 3092
  Resources: audio-in audio-out BuiltInSpeakerDevice
  ```

- `coreaudiod` consumed a sustained 9.4–15.0% CPU while Pancake was idle.
- Pancake's own process used approximately 0–0.3%; the cost was in `coreaudiod`.
- The watchdog logged every five seconds:

  ```text
  health: cycles=… (+469) hub=0.000 agg=551 running=1 subs=5 | BuiltInSpeakerDevice: wrote=0.000 running=0
  ```

  `469 / 5 s = 93.8 callbacks/s`, exactly the expected cadence for 512 frames at 48 kHz. The aggregate continued cycling despite zero hub input, zero output, and the physical output reporting not running.

- Quitting Pancake removed the aggregate assertion immediately and reduced `coreaudiod` to 0.8–1.2% CPU.
- Relaunching Pancake recreated the assertion within four seconds.
- `pancake status` reported `14 registered, no duplicates`, so this was **not** the older AirPlayXPCHelper registration storm documented in `COREAUDIOD-STORM.md`.

The acute three-hour battery incident also included an independent Finder/IconServices runaway at roughly 115–140% CPU combined. Do not attribute the entire discharge to Pancake. Pancake's contribution is nevertheless real, continuous, independently reproducible, and large enough to make an always-on audio utility unsuitable on battery.

## Existing project evidence

`CLAUDE.md:278-287` already records the same mechanism and nearly identical measurements:

- 1.6% `coreaudiod` without Pancake;
- 9.8% for the built-in-speaker aggregate;
- 11.4% after adding the built-in microphone;
- 14.9% for the five-device aggregate;
- `PreventUserIdleSystemSleep` held for the engine's lifetime.

`CLAUDE.md:338-343` explicitly deferred idle IO until battery complaints or idle CPU above roughly 14%. Both thresholds are now met.

## Code path

No code was changed during this investigation.

1. `Sources/PancakeApp/AppModel.swift:95-137`
   - `AppModel.init()` constructs the engine and calls `engine.start()` unconditionally.
2. `Sources/PancakeCore/Engine/Engine.swift:117-137`
   - `start()` installs monitors/timers and immediately calls `rebuild()`.
3. `Sources/PancakeCore/Engine/Engine.swift:912-1037`
   - `rebuild()` creates the private aggregate and unconditionally calls `AudioDeviceStart(agg.id, proc)`.
4. `Sources/PancakeCore/Engine/Engine.swift:1067-1107`
   - The watchdog observes the permanent callback stream. If cycles stop for two checks, it treats that as a fault and forces a rebuild. There is no intentional-idle state.
5. `Sources/PancakeCore/Engine/Engine.swift:839-857`
   - IO stops only during teardown: rebuild, degradation, or application shutdown.

The active graph explains `subs=5`: Pancake hub, Pancake Mic, Pancake Program, built-in microphone, and built-in speakers. It also contains Helium, Ableton Live, and Java process-tap nodes. Existing measurements say process taps add no measurable idle cost; the physical speaker and microphone dominate the incremental aggregate cost.

`AudioDevice.isRunningSomewhere` is already exposed in `Sources/PancakeCore/CoreAudio/AudioDevice.swift:145-147`, but the existing project note correctly says it cannot detect external demand here: Pancake's own aggregate keeps the virtual devices “running somewhere.”

## Required behavior

A fix should preserve the always-available routing stack while eliminating permanent idle IO:

1. Add an explicit engine state distinct from `.stopped`, `.running`, and `.degraded`, e.g. suspended/idle.
2. After a silence grace period, stop the aggregate IOProc when all of these are true:
   - no external process is running output on Pancake;
   - no external process is running input on Pancake Mic;
   - no recorder is armed;
   - no source that requires continuous capture is active (physical input, live process tap, or Program/Stage route).
3. Detect external demand using `kAudioProcessPropertyDevices` plus `kAudioProcessPropertyIsRunningOutput` / `IsRunningInput`, as already sketched in `CLAUDE.md`. Do not use `DeviceIsRunningSomewhere` for the hub/mic decision.
4. Wake the existing aggregate/IOProc on demand rather than rebuilding topology unless CoreAudio requires it.
5. Teach the watchdog that intentionally stopped cycles are healthy; it must not rebuild a suspended engine.
6. Keep default-output pinning and graph state alive while IO is suspended.
7. Bound and measure first-sound loss. A short startup gap is preferable to hours of permanent 10–15% CPU, but the wake path must be deterministic.

Before choosing the exact trigger, verify whether process running-state property notifications fire early enough to start the IOProc before meaningful audio is lost. If they do not, the driver may need to expose external-client activity separately from the aggregate's own client.

## Acceptance checks

With the current five-device graph:

- After the silence grace period, Pancake remains open and remains the default output.
- Pancake's aggregate `PreventUserIdleSystemSleep` assertion is absent.
- `coreaudiod` returns close to its no-Pancake baseline, not 10–15% CPU.
- Starting ordinary app playback wakes routing automatically and reaches the configured physical output.
- Pancake Mic, Program/Stage, process taps, and recording each prevent suspension while genuinely active.
- Stopping the final active client returns to idle after the grace period.
- Sleep/wake, Bluetooth reconnect, graph edits, coreaudiod restart recovery, and clean quit still work.
- Capture before/after `top`, `pmset -g assertions`, and watchdog logs for at least five idle minutes and several start/stop cycles.

## Adjacent shutdown race found during measurement

A normal AppleScript Quit logged:

```text
pancake app quitting
handed default output back to MacBook Pro Speakers
hal: default output changed
pinned default output to hub
```

After the process exited, `pancake status` confirmed both default output and default system output were left on Pancake with no engine running. The likely cause is a queued `HardwareMonitor` callback: `Engine.stop()` removes listeners, then changes the default output, but an already-enqueued `.defaultOutputChanged` callback reaches `handle(_:)`, which has no stopped/terminating guard and calls `pinDefaultOutput()`.

This is separate from idle battery use, but it makes “quit Pancake on battery” unsafe as a workaround because it can leave the machine routed to a silent virtual device. During this investigation Pancake was relaunched to restore the essential routing stack.

## Outcome (2026-10-14)

The owner declined automatic idle IO: the laptop plays live music, and an engine that stops and
starts IO on its own judgement is a way to fumble a set. The two deterministic fixes went in
instead — the shutdown race above (`Engine.halted`) and a dark-wake rebuild storm found while
reading the same log (the watchdog rebuilt the aggregate every 10 s of every maintenance wake,
28,091 times; see `CLAUDE.md` → "Dark wakes stop IO"). Remaining levers, all manual, are listed
under `CLAUDE.md` next-steps item 7.
