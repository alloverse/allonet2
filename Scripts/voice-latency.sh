#!/bin/sh
# Pipeline latency from a voicedemo latency log: join capture and render lines on media id and
# sequence, one distribution per stream. voicedemo prints the same numbers live every 5 s.
#
#   swift run AlloPlace -n Latency -p 9280 -u 13000-14000 &
#   VOICEDEMO_TONE=440 VOICEDEMO_LATENCY_LOG=/tmp/lat.log swift run voicedemo alloplace2://localhost:9280 &  # twice
#   ./Scripts/voice-latency.sh /tmp/lat.log
#
# Excludes what the output device adds after the render callback; voicedemo reports that.

set -eu
log="${1:-/tmp/lat.log}"
deltas=$(mktemp)
trap 'rm -f "$deltas"' EXIT

awk '$1 == "capture" { c[$2 " " $3] = $4; next }
     $1 == "render"  { k = $2 " " $3; if (k in c) printf "%s %.3f\n", $2, ($4 - c[k]) * 1000 }' "$log" > "$deltas"

for stream in $(awk '{print $1}' "$deltas" | sort -u); do
    awk -v s="$stream" '$1 == s { print $2 }' "$deltas" | sort -n | awk -v s="$stream" '
        { v[NR] = $1 }
        END { printf "latency %s: pipeline p50=%.0f p95=%.0f ms (n=%d)\n", s, v[int(NR*0.5)+1], v[int(NR*0.95)+1], NR }'
done
