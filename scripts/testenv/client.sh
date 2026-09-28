#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/common.sh"

: "${CLIENT_STATE_DIR:?}"

start() {
    : "${CONFIG_DIR:?}"
    : "${CLIENT_LOG_LEVEL:?}"
    : "${CLIENT_IMAGE:?}"
    : "${DOCKER_NETWORK:?}"
    if docker container inspect gnosis_vpn-client >/dev/null 2>&1; then
        echo "gnosis_vpn-client already exists — skipping start"
        return 0
    fi
    mkdir -p "${CLIENT_STATE_DIR}"

    local blokli_url extra_id_pass running
    blokli_url=$(sed 's/localhost/host.docker.internal/' "${CONFIG_DIR}/blokli_url")
    extra_id_pass=$(cat "${CONFIG_DIR}/extra_id.password")

    # The client's embedded node is the PIX Entry, so under the Curvy pool it needs what the nodes
    # get: the pool's HOPRD_CURVY_* overrides, and the proving keys it allocates deposits with.
    local curvy_args=()
    if [ "${CLUSTER_PIX_POOL:-}" = "curvy" ]; then
        load_curvy_env
        curvy_args=(
            --env HOPRD_CURVY_SHIELDING --env HOPRD_CURVY_SUBMISSION --env HOPRD_CURVY_RELAYER_URL
            --env HOPRD_CURVY_NOTE_SOURCE --env HOPRD_CURVY_TOKEN
            --env CURVY_ZK_KEYS_DIR=/curvy-zk --volume "${CURVY_ZK_KEYS_DIR}:/curvy-zk:ro"
        )
    fi

    docker run --detach --rm \
        --name gnosis_vpn-client \
        --network "${DOCKER_NETWORK}" \
        --cap-add=NET_ADMIN \
        --device /dev/net/tun \
        --add-host=host.docker.internal:host-gateway \
        --env RUST_LOG="${CLIENT_LOG_LEVEL}" \
        --env GNOSISVPN_CONFIG_PATH=/config/client.toml \
        --env GNOSISVPN_HOPR_BLOKLI_URL="${blokli_url}" \
        --env GNOSISVPN_HOPR_IDENTITY_FILE=/config/extra_id.id \
        --env GNOSISVPN_HOPR_IDENTITY_PASS="${extra_id_pass}" \
        --env GNOSISVPN_HOME=/var/lib/gnosisvpn \
        --env GNOSISVPN_CLIENT_AUTOSTART=30min \
        --volume "${CONFIG_DIR}:/config:ro" \
        --volume "${CLIENT_STATE_DIR}:/var/lib/gnosisvpn" \
        "${curvy_args[@]}" \
        "${CLIENT_IMAGE}"
    sleep 1
    running=$(docker inspect gnosis_vpn-client 2>/dev/null | jq -r '.[0].State.Running // "false"')
    if [ "${running}" != "true" ]; then
        echo "Error: gnosis_vpn-client failed to start" >&2
        { docker logs gnosis_vpn-client 2>&1 || true; } >&2
        exit 1
    fi
    echo "Started gnosis_vpn-client"
}

# Stop the client wherever it is running — container or host-native.
stop() {
    docker stop gnosis_vpn-client 2>/dev/null || true
    # only touch sudo if a host-native client is actually running, so the container-only
    # workflow (the common case) never hits a sudo prompt here
    if pgrep -f gnosis_vpn-root >/dev/null 2>&1 || pgrep -f gnosis_vpn-worker >/dev/null 2>&1; then
        sudo pkill -f gnosis_vpn-root 2>/dev/null || true
        sudo pkill -f gnosis_vpn-worker 2>/dev/null || true
    fi
}

start_on_host() {
    : "${CONFIG_DIR:?}"
    : "${GVPN_CLIENT_DIR:?}"
    : "${CLIENT_WORKER_USER:?}"
    : "${CLIENT_LOG_LEVEL:?}"
    : "${CLIENT_LOG_FILE:?}"
    local root_bin="${GVPN_CLIENT_DIR}/result/bin/gnosis_vpn-root"
    local worker_bin="${GVPN_CLIENT_DIR}/result/bin/gnosis_vpn-worker"
    if [ ! -f "${root_bin}" ] || [ ! -f "${worker_bin}" ]; then
        die "Error: gnosis_vpn-client binaries not found at ${GVPN_CLIENT_DIR}/result/bin/" \
            "Run 'just build-client-native' to build them first"
    fi
    id "${CLIENT_WORKER_USER}" >/dev/null 2>&1 || die \
        "Error: worker user '${CLIENT_WORKER_USER}' not found on this host." \
        "gnosis_vpn-root drops privileges to this user (by uid/gid) when spawning gnosis_vpn-worker," \
        "so it must already exist as a system account (its home directory is irrelevant — create" \
        "one via your NixOS config, or override the name via CLIENT_WORKER_USER)."
    if pgrep -f gnosis_vpn-root >/dev/null 2>&1; then
        echo "Client already running on host — skipping start"
        return 0
    fi
    mkdir -p "${CLIENT_STATE_DIR}"

    local blokli_url extra_id_pass
    blokli_url=$(cat "${CONFIG_DIR}/blokli_url")
    extra_id_pass=$(cat "${CONFIG_DIR}/extra_id.password")

    # sudo backgrounded can't read TTY; pre-authenticate while still interactive
    sudo -v
    sudo RUST_LOG="${CLIENT_LOG_LEVEL}" \
        GNOSISVPN_CONFIG_PATH="${CONFIG_DIR}/client.toml" \
        GNOSISVPN_HOPR_BLOKLI_URL="${blokli_url}" \
        GNOSISVPN_HOPR_IDENTITY_FILE="${CONFIG_DIR}/extra_id.id" \
        GNOSISVPN_HOPR_IDENTITY_PASS="${extra_id_pass}" \
        GNOSISVPN_HOME="${CLIENT_STATE_DIR}" \
        GNOSISVPN_CLIENT_AUTOSTART=30min \
        GNOSISVPN_WORKER_USER="${CLIENT_WORKER_USER}" \
        GNOSISVPN_LOG_FILE="${CLIENT_LOG_FILE}" \
        "${root_bin}" --worker-binary "${worker_bin}" &
    echo "Client PID: $!"
}

# Cascades SIGTERM to the worker via gnosis_vpn-root.
stop_on_host() {
    sudo pkill -f gnosis_vpn-root 2>/dev/null || true
    sudo pkill -f gnosis_vpn-worker 2>/dev/null || true
    echo "Client (host) stopped"
}

# Escalates only when it has to. The *container's* entrypoint chowns this bind-mounted dir to its
# internal worker uid, so the host user cannot remove it afterwards — but when the client ran on the
# host, or never ran at all, the directory is plainly removable or absent. Asking for a password
# there failed the whole `down` on a shell without a tty, after everything else had already stopped.
purge_state() {
    if [ ! -e "${CLIENT_STATE_DIR}" ]; then
        echo "${CLIENT_STATE_DIR} does not exist — nothing to purge"
        return 0
    fi
    if rm -rf "${CLIENT_STATE_DIR}" 2>/dev/null; then
        echo "Purged ${CLIENT_STATE_DIR}"
        return 0
    fi
    sudo rm -rf "${CLIENT_STATE_DIR}"
    echo "Purged ${CLIENT_STATE_DIR} (needed sudo)"
}

purge_state_interactive() {
    local answer
    read -r -p "Permanently delete '${CLIENT_STATE_DIR}'? Type 'yes' to confirm: " answer
    [ "${answer}" = "yes" ] || die "Aborted"
    sudo rm -rf "${CLIENT_STATE_DIR}"
    echo "Purged ${CLIENT_STATE_DIR}"
}

case "${1:-}" in
start) start ;;
stop) stop ;;
start-on-host) start_on_host ;;
stop-on-host) stop_on_host ;;
purge-state) purge_state ;;
purge-state-interactive) purge_state_interactive ;;
*) die "usage: client.sh start|stop|start-on-host|stop-on-host|purge-state|purge-state-interactive" ;;
esac
