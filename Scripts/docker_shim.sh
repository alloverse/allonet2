#!/usr/bin/env bash
set -euo pipefail

# A container on several networks resolves to several IPs, but -l takes one
# mapping. One rewritten public candidate is enough for ICE, so use the first.
INTERNAL_IP="$(getent hosts "$(hostname)" | awk 'NR==1 {print $1}')"
PUBLIC_ADDR="${PUBLIC_ADDR:?set PUBLIC_ADDR env var (DNS name or IP)}"

echo "Launching AlloPlace replacing IP ${INTERNAL_IP} with ${PUBLIC_ADDR}"

exec /usr/local/bin/AlloPlace -l "${INTERNAL_IP}-${PUBLIC_ADDR}" "$@"