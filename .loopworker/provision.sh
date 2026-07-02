#!/usr/bin/env bash
# ONE-TIME per slot: init submodules (local package deps live in Packages/) and warm one
# build so the merge gate runs incrementally. First build downloads webrtc-xcframework (big).
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"
git submodule update --init --recursive
swift build
