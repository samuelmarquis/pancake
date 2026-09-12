# tools

Throwaway CoreAudio probes from reverse-engineering the Loopback gain bug
(`../NOTES.md`). They work today and need no build step.

```sh
swift listvol.swift                 # every output device: name, UID, per-element volume
swift setvol.swift <deviceUID> 1.0  # set a device's hardware volume (0.0–1.0)
```

`listvol` reports per-element volumes because devices disagree about where the
control lives — the AirPods expose elements 1 and 2 with no element-0 main
control, while built-in speakers and the Loopback virtual device expose element 0
only. Anything setting volume must iterate elements rather than assume element 0.

Kept because they're the fastest way to check what the HAL actually thinks is
going on, and M2 will want exactly this device enumeration.
