#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/common.sh"

: "${SERVER_COUNT:?}"

start() {
    : "${SERVER_LOG_LEVEL:?}"
    local i name wg_port api_port private_key running
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        name="gnosis_vpn-server-${i}"
        wg_port=$((51821 + i))
        api_port=$((8000 + i))
        if docker container inspect "${name}" >/dev/null 2>&1; then
            echo "${name} already exists — skipping start"
            echo "  WireGuard: ${wg_port}/udp, API: ${api_port}"
            continue
        fi
        private_key=$(wg genkey)
        docker run --rm --detach \
            --env "PRIVATE_KEY=${private_key}" \
            --env "RUST_LOG=${SERVER_LOG_LEVEL}" \
            --publish "${api_port}:8000" \
            --publish "${wg_port}:51820/udp" \
            --cap-add=NET_ADMIN \
            --add-host=host.docker.internal:host-gateway \
            --sysctl net.ipv4.conf.all.src_valid_mark=1 \
            --sysctl net.ipv4.ip_forward=1 \
            --name "${name}" \
            gnosis_vpn-server
        sleep 1
        running=$(docker inspect "${name}" 2>/dev/null | jq -r '.[0].State.Running // "false"')
        if [ "${running}" != "true" ]; then
            echo "Error: ${name} failed to start" >&2
            { docker logs "${name}" 2>&1 || true; } >&2
            exit 1
        fi
        echo "Started ${name} — WireGuard: ${wg_port}/udp, API: ${api_port}"
    done
}

stop() {
    local i
    for i in $(seq 0 $((SERVER_COUNT - 1))); do
        docker stop "gnosis_vpn-server-${i}" 2>/dev/null &&
            echo "Stopped gnosis_vpn-server-${i}" ||
            echo "gnosis_vpn-server-${i} was not running"
    done
}

case "${1:-}" in
start) start ;;
stop) stop ;;
*) die "usage: server.sh start|stop" ;;
esac
