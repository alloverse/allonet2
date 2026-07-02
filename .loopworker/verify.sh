#!/usr/bin/env bash
# The merge gate: submodules current, then build + tests. Any nonzero exit fails the gate.
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"
git submodule update --init --recursive
swift build
swift test
