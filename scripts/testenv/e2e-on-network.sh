#!/usr/bin/env bash
# Owns its daemon like system-tests: sudo for WireGuard, the worker runs as you, full tunnel while it runs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/common.sh"

: "${REPO_DIR:?}"
: "${E2E_IMAGE:?}"
: "${E2E_OUT_DIR:?}"
: "${E2E_ROOT_BINARY:?E2E_ROOT_BINARY must point at a gnosis_vpn-root binary for this host}"
: "${E2E_WORKER_BINARY:?E2E_WORKER_BINARY must point at a gnosis_vpn-worker binary for this host}"
: "${E2E_CONFIG:?E2E_CONFIG must point at a client config (e.g. jura-dev.toml)}"
: "${E2E_IDENTITY_FILE:?E2E_IDENTITY_FILE must point at the HOPR identity file}"
: "${E2E_IDENTITY_PASS_FILE:?E2E_IDENTITY_PASS_FILE must point at a file holding the identity password}"
: "${E2E_BLOKLI_URL:?E2E_BLOKLI_URL must be set (e.g. https://blokli.jura.dev.gnosisvpn.io)}"

# Default to the .safe sitting next to the identity, as gnosis_vpn lays it out
safe_file="${E2E_IDENTITY_SAFE_FILE:-${E2E_IDENTITY_FILE%.id}.safe}"
if [ ! -f "${safe_file}" ]; then
    echo "WARNING: no .safe found next to the identity (${safe_file}); the client will try to onboard a NEW safe" >&2
    safe_file=""
fi

CLIENT_MODE=spawn \
    GVPN_ROOT_BIN="${E2E_ROOT_BINARY}" \
    GVPN_WORKER_BIN="${E2E_WORKER_BINARY}" \
    GVPN_CONFIG="${E2E_CONFIG}" \
    GVPN_IDENTITY_FILE="${E2E_IDENTITY_FILE}" \
    GVPN_IDENTITY_PASS="$(cat "${E2E_IDENTITY_PASS_FILE}")" \
    GVPN_IDENTITY_SAFE="${safe_file}" \
    GVPN_BLOKLI_URL="${E2E_BLOKLI_URL}" \
    PING_TARGETS="${PING_TARGETS:-1.1.1.1,10.128.0.1}" \
    "${REPO_DIR}/e2e/run.sh" "$@"
