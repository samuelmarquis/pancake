# Pancake.driver

The HAL plug-in (`AudioServerPlugIn`) that gives the system two virtual devices:

| Device | UID | Role | Controls |
|---|---|---|---|
| **Pancake** | `Pancake_UID` | The system output. Apps play here; the engine reads it back. | Output volume + mute — the volume keys drive this, and it's applied once, in the driver. |
| **Pancake Mic** | `PancakeMic_UID` | The engine writes here; apps (Discord…) record from it. | None. Unity gain, always. |

Both are stereo, Float32, 44.1/48/88.2/96 kHz, and share one host-time clock.

## Provenance

A fork of [BlackHole](https://github.com/ExistentialAudio/BlackHole) 0.7.1 (commit in
`BLACKHOLE_COMMIT`), which is **GPL-3.0** — not MIT as earlier notes said. `LICENSE` is
BlackHole's. Every local change is marked with a `pancake:` comment in `Pancake.c`; the
substantive one is that upstream's second device ("Mirror") shares the first device's ring
buffer, and ours doesn't, so the two devices carry independent audio.

The plug-in is a separate process boundary from the engine (it runs inside `coreaudiod`
and the engine only ever talks to it through the HAL), so the Swift side isn't bound by the
GPL. Keep it that way: no shared code between `driver/` and `Sources/`.

## Build & install

```sh
make                 # → build/Pancake.driver, ad-hoc signed
sudo make install    # copies to /Library/Audio/Plug-Ins/HAL, restarts coreaudiod
make check           # installed copy == built copy?
sudo make uninstall
```

Needs only Command Line Tools. Restarting `coreaudiod` drops every audio stream on the
machine for about a second; Loopback, Ableton, etc. reconnect on their own.

If the devices don't appear after install:

```sh
log show --last 2m --predicate 'process == "coreaudiod"' | grep -i -E 'pancake|plug-?in|error'
```

Bundle ID is `com.pancake.driver`; the CFPlugIn factory UUID lives in `Pancake.plist` and
must stay unique among installed HAL plug-ins.
