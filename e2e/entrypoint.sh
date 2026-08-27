#!/usr/bin/env bash
# Starts obscura's CDP server, then runs the harness against it. Both live in the
# gnosis_vpn-client container's network namespace, so 127.0.0.1 is shared and all
# browser traffic egresses through the tunnel.
set -euo pipefail

CDP_PORT="${CDP_PORT:-9222}"

obscura serve --port "$CDP_PORT" --stealth >/tmp/obscura-serve.log 2>&1 &
OBSCURA_PID=$!
trap 'kill "$OBSCURA_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
    curl -sf --max-time 2 "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null && break
    sleep 0.5
done
if ! curl -sf --max-time 2 "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null; then
    echo "obscura did not come up on 127.0.0.1:${CDP_PORT}" >&2
    cat /tmp/obscura-serve.log >&2
    exit 1
fi

export CDP="${CDP:-ws://127.0.0.1:${CDP_PORT}/devtools/browser}"
# not exec'd, so the EXIT trap above still gets to stop obscura
node /app/harness.mjs "$@"
