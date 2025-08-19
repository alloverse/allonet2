#!/usr/bin/env bash
set -euo pipefail

INTERNAL_IP="$(getent hosts "$(hostname)" | awk '{print $1}')"
PUBLIC_ADDR="${PUBLIC_ADDR:?set PUBLIC_ADDR env var (DNS name or IP)}"

echo "Launching AlloPlace replacing IP ${INTERNAL_IP} with ${PUBLIC_ADDR}"

exec /usr/local/bin/AlloPlace -l "${INTERNAL_IP}-${PUBLIC_ADDR}" "$@"