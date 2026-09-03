#!/bin/sh
# Glass-to-glass latency from a screendemo log: capture-to-enqueue per picture, joined on media
# id and frame timestamp. Same four-field format voicedemo writes, so the voice script computes
# it unchanged; both ends must run on one machine, since the times are one monotonic clock.
#
#   swift run AlloPlace -n Screen -p 9180 -u 12000-13000 -b 127.0.0.1 &
#   SCREENDEMO_BIND=127.0.0.1 SCREENDEMO_PATTERN=1280x720@15 SCREENDEMO_LATENCY_LOG=/tmp/screenlat.log \
#       swift run screendemo alloplace2://localhost:9180 --share &
#   SCREENDEMO_BIND=127.0.0.1 SCREENDEMO_LATENCY_LOG=/tmp/screenlat.log \
#       swift run screendemo alloplace2://localhost:9180 --view &
#   ./Scripts/screen-latency.sh /tmp/screenlat.log
exec "$(dirname "$0")/voice-latency.sh" "${1:-/tmp/screenlat.log}"
