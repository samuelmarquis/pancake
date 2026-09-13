#!/bin/bash
# Capture the whole-system audio picture while coreaudiod is misbehaving (a CPU storm, hangs), so the
# cause can be worked out afterwards instead of reconstructed from memory.
#
#   sudo tools/storm-snapshot.sh            # full capture, incl. a symbolicated sample of coreaudiod
#   tools/storm-snapshot.sh                 # without sudo: everything except the coreaudiod sample
#
# Writes ~/Desktop/pancake-storm-<timestamp>/ and prints the path. Every step that talks to the HAL
# or the unified log runs under a timeout, because a saturated coreaudiod hangs new clients — the
# snapshot must finish even when the machine is at its worst. Nothing here changes system state.
#
# Background (2026-09-13): coreaudiod sat at 100–200% for ~40 minutes after two driver installs,
# survived every pancake process being killed and coreaudiod restarts, and stopped when Wi-Fi
# reconnected. The diagnostics showed every request "originated by" AirPlayXPCHelper and clients
# re-enumerating the device list nonstop. A controlled repro (restart ± pancake ± Stage ± AirPlay
# ± v4 driver ± Ableton) never reproduced it. This script is so the next occurrence is evidence.

set -u
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo "~$REAL_USER")
HERE=$(cd "$(dirname "$0")" && pwd)
TS=$(date +%Y%m%d-%H%M%S)
OUT="$REAL_HOME/Desktop/pancake-storm-$TS"
mkdir -p "$OUT"

# run_for SECONDS OUTFILE CMD... — run CMD in the background, kill it if it outlives SECONDS.
run_for() {
    local secs=$1 out=$2; shift 2
    ( "$@" > "$out" 2>&1 ) &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$secs" ]; then
            kill -9 "$pid" 2>/dev/null
            echo "[storm-snapshot: TIMED OUT after ${secs}s — probably blocked on coreaudiod]" >> "$out"
            break
        fi
        sleep 1; i=$((i + 1))
    done
    wait "$pid" 2>/dev/null
}
step() { printf '  %-44s' "$1"; }
done_() { echo "done"; }

echo "pancake storm snapshot → $OUT"

step "system + time";          { date; sw_vers; uptime; } > "$OUT/00-system.txt" 2>&1; done_

step "top (instantaneous, 25 busiest)"
run_for 20 "$OUT/01-top.txt" top -l 2 -s 2 -o cpu -n 25 -stats pid,user,cpu,time,threads,command; done_

step "audio daemons + pancake processes"
ps -eo pid,user,%cpu,etime,command | grep -iE "coreaudiod|Core Audio Driver|AirPlay|mediaremoted|universalaccessd|audioaccessoryd|bluetoothd|Pancake|pancake" | grep -v grep > "$OUT/02-processes.txt"; done_

step "coreaudiod CPU over 10s"
{ for i in 1 2 3 4 5; do top -l 2 -s 1 -stats pid,cpu,command 2>/dev/null | awk '/^PID/{n++} n==2' | grep -E "coreaudiod|AirPlayXPC|mediaremoted|universalacc|Pancake" | sed "s/^/$(date +%H:%M:%S) /"; done; } > "$OUT/03-cpu-trend.txt" 2>&1; done_

step "coreaudiod sample (needs sudo)"
if [ "$(id -u)" = 0 ]; then
    run_for 30 "$OUT/04-coreaudiod.sample.log" sample coreaudiod 3 -file "$OUT/04-coreaudiod.sample"; done_
else
    echo "skipped: not root" > "$OUT/04-coreaudiod.sample"; echo "skipped (run with sudo)"
fi

step "HAL state (devices, taps, defaults, IO)"
if command -v swiftc >/dev/null; then
    swiftc -O -o "$OUT/.halstate" "$HERE/halstate.swift" 2>/dev/null
    if [ -x "$OUT/.halstate" ]; then
        # As the real user, not root — the HAL view (and TCC) is per user.
        if [ "$(id -u)" = 0 ]; then run_for 25 "$OUT/05-hal-state.txt" sudo -u "$REAL_USER" "$OUT/.halstate"
        else run_for 25 "$OUT/05-hal-state.txt" "$OUT/.halstate"; fi
        rm -f "$OUT/.halstate"; done_
    else echo "compile failed" | tee "$OUT/05-hal-state.txt"; fi
else echo "no swiftc" | tee "$OUT/05-hal-state.txt"; fi

step "CPU-resource diagnostics (last 2h)"
{
    for d in $(find /Library/Logs/DiagnosticReports "$REAL_HOME/Library/Logs/DiagnosticReports" -maxdepth 1 \
                 \( -name 'coreaudiod*' -o -name 'AirPlay*' -o -name 'mediaremoted*' -o -name 'universalaccessd*' -o -name 'Pancake*' \) \
                 -mmin -120 2>/dev/null); do
        echo "===== $d"
        grep -E "^(Event|Start time|End time|Duration|On Behalf Of)" "$d" | head -8
        awk '/Heaviest stack for the target process/{f=1;next} /^$/{if(f)exit} f' "$d" | sed 's/^ *//' | cut -c1-150 | tail -18
        cp "$d" "$OUT/" 2>/dev/null
    done
} > "$OUT/06-diagnostics.txt" 2>&1; done_

step "pancake log (last 600 lines)"
tail -600 "$REAL_HOME/Library/Logs/pancake.log" > "$OUT/07-pancake.log" 2>/dev/null; done_

step "pancake HAL events per minute"
awk '{m=substr($1,1,5); if ($0~/hal: devices changed/) d[m]++; if ($0~/same set/) s[m]++; if ($0~/process list changed/) p[m]++;
      if ($0~/default input changed/) di[m]++; if ($0~/default output changed/) o[m]++; seen[m]=1}
     END{for (m in seen) printf "%s devices=%d same-set=%d procs=%d defIn=%d defOut=%d\n", m, d[m], s[m], p[m], di[m], o[m]}' \
    "$OUT/07-pancake.log" | sort > "$OUT/08-hal-events-per-minute.txt"; done_

step "graph + layout config"
cp "$REAL_HOME/.config/pancake/"*.json "$OUT/" 2>/dev/null; done_

step "Bluetooth + Wi-Fi/AWDL state"
run_for 25 "$OUT/09-bluetooth.txt" system_profiler SPBluetoothDataType
{ ifconfig awdl0 2>&1 | head -6; echo; networksetup -getairportpower en0 2>&1; } > "$OUT/10-network.txt"; done_

step "unified log, last 3 min (tallied)"
run_for 90 "$OUT/11-unified-log.txt" log show --last 3m --info --style compact \
    --predicate 'process == "coreaudiod" OR process == "AirPlayXPCHelper" OR process == "mediaremoted" OR process == "universalaccessd" OR process == "PancakeStage" OR subsystem BEGINSWITH "com.apple.coreaudio" OR subsystem BEGINSWITH "com.apple.airplay"'
{
    echo "lines per process:"
    awk 'NR>1 && $4 ~ /\[/ {split($4,a,"["); print a[1]}' "$OUT/11-unified-log.txt" | sort | uniq -c | sort -rn | head -20
    echo; echo "most repeated messages (numbers/ids collapsed):"
    sed -E 's/^[^ ]+ [^ ]+ +[^ ]+ +[^ ]+ +//; s/0x[0-9a-f]+|[0-9A-Fa-f-]{16,}|[0-9]+/#/g' "$OUT/11-unified-log.txt" | cut -c1-160 | sort | uniq -c | sort -rn | head -30
} > "$OUT/12-unified-log-tally.txt" 2>&1; done_

[ "$(id -u)" = 0 ] && chown -R "$REAL_USER" "$OUT"
echo
echo "Snapshot written to $OUT"
echo "Also note, in words: what you were doing in the minutes before (AirPlay, calls, driver installs, apps opened)."
