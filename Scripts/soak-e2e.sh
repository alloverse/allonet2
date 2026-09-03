#!/usr/bin/env bash
# Run the end-to-end suites N times, killing any run that hangs.
# Usage: soak-e2e.sh [runs] [seconds-per-run]
set -uo pipefail
cd "$(dirname "$0")/.."
runs=${1:-20}
limit=${2:-180}
pass=0; fail=0; hang=0
for i in $(seq 1 "$runs"); do
    log=/tmp/soak-e2e-$i.log
    swift test --filter "VoiceE2ETests|ScreenE2ETests" >"$log" 2>&1 &
    pid=$!
    ( sleep "$limit"; kill -9 $pid 2>/dev/null ) & watchdog=$!
    if wait $pid; then pass=$((pass+1)); echo "run $i ok"; else
        if kill -0 $watchdog 2>/dev/null; then fail=$((fail+1)); echo "FAIL run $i ($log)";
        else hang=$((hang+1)); echo "HANG run $i ($log)"; fi
    fi
    kill $watchdog 2>/dev/null
done
echo "GATE runs=$runs pass=$pass fail=$fail hang=$hang"
[ "$pass" -eq "$runs" ]
