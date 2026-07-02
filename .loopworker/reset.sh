#!/usr/bin/env bash
# PER-ACQUIRE: the Manager already hard-reset the worktree to a fresh branch off the base
# ref, which moves submodule gitlinks but not their checked-out worktrees — resync them.
set -euo pipefail
cd "$LOOPWORKER_SLOT_DIR"
git submodule update --init --recursive
