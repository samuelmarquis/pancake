# Notes: what Loopback actually does with volume

Measured 2026-09-11 against **Loopback 2.4.10**, macOS 26.3 (Darwin 25.3.0).
Recorded because it's the entire motivation for pancake's gain design, and
because re-deriving it is tedious.

## There are three separate volume levels, not one

This is the thing that makes the problem confusing to reason about.

| # | Level | Lives in | Observed |
|---|---|---|---|
| 1 | System volume on the `Loopback Audio` device | CoreAudio, `kAudioDevicePropertyVolumeScalar` | 0.6875 |
| 2 | Loopback's internal device `volumeLevel` | `Devices.plist` | 100 |
| 3 | Per-**monitor** gain (the buggy one) | `Devices.plist`, inside a base64 blob | see below |

Level 1 is what the volume keys drive. `0.6875` is exactly `11/16` — macOS volume
keys move in sixteenths, so that value was reached by discrete keypresses, not by
drift. **Level 1 is the user's actual volume control and must not be pinned.**

Level 3 is the one that silently resets to ~50%.

## Where the monitor gain lives

`~/Library/Application Support/Loopback/Devices.plist` → `modelItems[0]` →
`patchSubModels[]` → entries with `className == "LBMonitor"` →
`audioDeviceReference.device`.

That last field is **not** a plist type — it's the ASCII string `ACPDevice:`
followed by JSON, stored as a `<data>` blob. Decoder:

```python
import plistlib, json, os
p = os.path.expanduser('~/Library/Application Support/Loopback/Devices.plist')
d = plistlib.load(open(p, 'rb'))
for it in d['modelItems'][0]['patchSubModels']:
    if it.get('className') != 'LBMonitor':
        continue
    r = it['audioDeviceReference']
    j = json.loads(r['device'].decode('utf-8', 'replace').split('ACPDevice:', 1)[1])
    print(f"{r['name']!r:26} v={j.get('v')} enabled={it['enabled']}")
```

Fields in that JSON: `v` = volume (1 == 100%), `mt` = muted, `hv`/`hm` = has
volume / has mute, `t` = transport (`blue` bluetooth, `bltn` built-in), `n` name,
`m` manufacturer, `md` model, `r` sample rate, `c` channels, `ar` available rates.

Observed on this machine:

```
'AÀÂÃÅÄĄ'              v=1                    enabled=True
'JBL Charge 5'         v=0.3779526948928833   enabled=False
'MacBook Pro Speakers' v=1                    enabled=False
```

The JBL's `0.3779` is the bug preserved in amber — a monitor left at 38%.

## Two experiments, both negative

The obvious hypothesis was that a monitor's slider is a passthrough to the
physical device's hardware volume, which would mean it could be pinned from
outside Loopback via CoreAudio. **It is not.**

1. Set `BuiltInSpeakerDevice` hardware volume → `0.42` via CoreAudio.
   Loopback did not react. (Weak: that monitor was disabled.)
2. Set the AirPods (`F0-04-E1-C9-6A-F8:output`) hardware volume → `0.50`, on the
   **enabled** monitor. Loopback neither reflected it nor rewrote `Devices.plist`
   within 12 s. (Both restored to 1.0 afterwards.)

Reproduce either with `tools/setvol.swift` + `tools/listvol.swift`.

**Conclusion: monitor gain is Loopback-internal software state.** It has no
CoreAudio surface.

## Why it can't be fixed from outside

- **No CoreAudio property** — per above.
- **No AppleScript.** `/Applications/Loopback.app` ships no `.sdef` and does not
  set `NSAppleScriptEnabled`. There is no scripting hook of any kind.
- **No preference for it.** `com.rogueamoeba.Loopback.plist` contains only window
  frames, update settings and the licence. Nothing about gain or gain locking.
- **Editing `Devices.plist` live doesn't work** — Loopback holds the model in
  memory and rewrites the file on its own schedule, clobbering external edits.

What's left: quit → edit → relaunch (only helps if the reset is persisted rather
than happening at runtime), or drive the slider through the Accessibility API,
which breaks on every update. Neither is worth building.

**The reasonable move is to report it to Rogue Amoeba**, who are responsive, and
who are the only ones who can actually fix it. That is orthogonal to pancake and
a fix from them would be free.

## Incidental findings

- AirPods are `F0-04-E1-C9-6A-F8:output`, transport `blue`, and expose volume on
  elements 1 and 2 (no element-0 main control). Anything setting their volume must
  iterate elements rather than assuming element 0.
- `MacBook Pro Speakers` (`BuiltInSpeakerDevice`) exposes element 0 only.
- `Loopback Audio`'s virtual device exposes element 0 only.
- macOS keeps a remembered volume **per output device** and restores it when that
  device becomes default. This is genuinely "an output level attached to each
  output device" — but it's macOS's behaviour, not Loopback's, and it is distinct
  from the level-3 bug above.
