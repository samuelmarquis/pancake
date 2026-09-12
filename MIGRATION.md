# Decommissioning Loopback

What has to be removed or retargeted when pancake takes over. Inventory verified
on this machine 2026-09-11.

Most of this is inert cleanup. **One item will actively fight pancake**, so read
that first.

---

## 1. The thing that fought: `audio-defaults` — REMOVED 2026-09-11

**Done.** The whole agent (output pin + input guard), its `switchaudio-osx` dependency, and the
`~/.config/audio-pin-off` escape hatch have been deleted from `home.nix` and `home-manager switch`d
out. pancake now owns both jobs: output via its default-output pin/follow, and — the part this doc
originally said to keep — **input via the per-section input lock**. With `policy.lockInput` set, the
engine pins the system default input to the mic feeding Pancake Mic and re-asserts it whenever
something (the AirPods on connect) grabs it, which is the HFP-avoidance the input half used to do.
Verified: forcing the default input to the AirPods, pancake pulls it back to the built-in mic. The
stale `audio-defaults.last` / `audio-defaults.log` / `audio-pin-off` files were removed too.

The original plan, for the record:



`~/.config/home-manager/home.nix` defines a launchd agent that **hard-pins the
system output to `"Loopback Audio"` every few seconds**. During M1–M3, when both
the Loopback and Pancake devices exist, it will yank output back to Loopback
within ~5–10 s of every attempt to test pancake. This will look like "pancake
doesn't work."

**Instant escape hatch, no rebuild required:**

```sh
touch ~/.config/audio-pin-off     # suspends output pinning; mic logic keeps running
rm    ~/.config/audio-pin-off     # resume
```

That file was built as an ergonomic escape for a hard pin; it happens to be
exactly the right cutover switch. Use it for all pancake bring-up.

**Permanent change at M4** — in `home.nix`:

- The **output half** (`loopback="Loopback Audio"`, the `## 1. Output` block)
  either retargets to `"Pancake"` or is deleted outright. Deleting is preferable:
  the entire reason it exists is that macOS auto-switches output away on AirPods
  connect, and once the system output is a virtual device that never disappears,
  there is nothing left to steal it.
- The **input half** (`## 2. Input`, built-in mic vs Bluetooth) is independent of
  all of this and should **stay**. AirPods hijacking the mic on connect is macOS
  behaviour that pancake doesn't touch.
- `switchaudio-osx` in `home.packages` exists only to drive this agent. It goes
  when the output half goes — unless pancake's CLI ends up wanting it, which it
  shouldn't, since it talks to CoreAudio directly.

Stale state to delete afterwards:

```
~/Library/Caches/audio-defaults.last
~/Library/Logs/audio-defaults.log
~/.config/audio-pin-off              (if present)
```

Home-manager removes the agent's plist and unloads it on switch; verify with
`launchctl list | grep audio-defaults`.

---

## 2. Loopback itself

**Back up the licence before uninstalling anything.** It lives in
`~/Library/Preferences/com.rogueamoeba.Loopback.plist` under `registrationInfo`
(name + code). Copy that file somewhere safe — a reinstall without it is a
support email.

Footprint on this machine:

| Path | Notes |
|---|---|
| `/Applications/Loopback.app` | |
| `~/Library/Application Support/Loopback/` | `Devices.plist`, `RecentApps.plist` |
| `~/Library/Preferences/com.rogueamoeba.Loopback.plist` | **licence lives here** |
| `~/Library/LaunchAgents/com.rogueamoeba.loopbackd.plist` | |
| `/Library/LaunchAgents/com.rogueamoeba.arkaudiod.plist` | |
| `/Library/Audio/Plug-Ins/HAL/ARK.driver` | **do not hand-delete — see below** |

**Use Rogue Amoeba's own uninstaller** (Loopback → menu bar → uninstall, or their
published removal tool). `ARK.driver` is a HAL plug-in loaded by `coreaudiod` and
is shared across their product line; ripping it out by hand risks leaving
`coreaudiod` in a bad state, and a wedged `coreaudiod` means no audio at all until
reboot.

Loopback **is the only Rogue Amoeba app installed here** (verified — no Audio
Hijack, SoundSource, Farrago, Fission or Piezo), so ARK can go with it. Re-check
that before uninstalling if that's changed, because removing ARK would break any
of those that appeared in the meantime.

---

## 3. References to `"Loopback Audio"` by name

The device name is a string in several places and none of them fail loudly:

- `~/.config/home-manager/home.nix` — see §1
- **Ableton Live** audio preferences — will silently fall back to another device
- Any other DAW or app pointed at it
- Anything in the DJ setup pointed at it rather than the DDJ-FLX4

There is no way to enumerate these programmatically. Grep configs, then expect to
find one or two the hard way.

---

## 4. Verified clean — don't worry about these

Checked so nobody re-investigates later:

- **`rekordbox Aggregate Device`** does **not** reference Loopback. Its
  sub-devices are `AppleUSBAudioEngine:AlphaTheta Corporation:DDJ-FLX4:…` and a
  Bluetooth output (`90-56-82-CF-B1-EA:output`). Removing Loopback won't break
  rekordbox. Re-check with `tools/lsaggregate.swift` if the DJ setup changes.
- **`/Library/Audio/Plug-Ins/HAL/ParrotAudioPlugin.driver`** is Apple's
  (`com.apple.audio.ParrotAudioPlugin`). Nothing to do with Loopback. Leave it.
- **`~/Library/Preferences/com.apple.audio.AudioMIDISetup.plist`** does not exist
  on this machine — no hand-built aggregates or multi-output devices to unpick.

---

## 5. Order of operations

Never uninstall Loopback before pancake is proven — the system output device
vanishing mid-cutover is genuinely disruptive, and you lose the ability to A/B
against a known-good implementation.

1. **M1–M3 bring-up.** Both devices installed. `touch ~/.config/audio-pin-off` so
   the agent stops fighting. Loopback stays fully functional as the fallback.
2. **M4.** pancake is the daily driver. Retarget or delete the output half of
   `audio-defaults`; keep the mic half. Rebuild home-manager, confirm the agent
   reloaded.
3. **Soak.** Live on pancake through at least one full DJ session and several
   AirPods connect/disconnect/sleep cycles before touching Loopback. M3 is the
   milestone most likely to be quietly incomplete.
4. **Uninstall.** Back up the licence, run Rogue Amoeba's uninstaller, reboot,
   confirm `ARK.driver` and both `com.rogueamoeba.*` launchd agents are gone.
5. **Clean up.** Delete the stale `audio-defaults` files from §1 and fix the
   name references in §3.
