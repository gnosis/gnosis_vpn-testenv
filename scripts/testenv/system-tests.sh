#!/usr/bin/env bash
# Runs gnosis_vpn-client's system-test binary against the live local stack. Full tunnel: while it
# runs, this machine's traffic egresses through the exit under test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/common.sh"

: "${CONFIG_DIR:?}"
: "${GVPN_CLIENT_DIR:?}"
: "${SYSTEM_TEST_LOG_LEVEL:?}"

for artifact in client.toml extra_id.id extra_id.password blokli_url; do
    [ -f "${CONFIG_DIR}/${artifact}" ] ||
        die "Missing ${CONFIG_DIR}/${artifact} — run 'just gen-config' first"
done

# The runner brings up its own client on `extra_id.id` — the same identity `client-start` hands the
# container. Two nodes sharing one chain key announce the same peer twice and fight over the Safe,
# so the container has to be down first. (`up` starts it; use the recipes it composes.)
if docker container inspect gnosis_vpn-client >/dev/null 2>&1; then
    die "The gnosis_vpn-client container is running — it holds the same HOPR identity this" \
        "test needs. Stop it first: just client-stop"
fi

# resolved through the symlink so the sudo'd runner gets stable /nix/store paths
root_binary=$(readlink -f "${GVPN_CLIENT_DIR}/result/bin/gnosis_vpn-root" 2>/dev/null || true)
worker_binary=$(readlink -f "${GVPN_CLIENT_DIR}/result/bin/gnosis_vpn-worker" 2>/dev/null || true)
ctl_binary=$(readlink -f "${GVPN_CLIENT_DIR}/result/bin/gnosis_vpn-ctl" 2>/dev/null || true)
for binary in "${root_binary}" "${worker_binary}" "${ctl_binary}"; do
    [ -x "${binary}" ] ||
        die "Missing client binaries in ${GVPN_CLIENT_DIR}/result/bin — run 'just build-client' first"
done

# Its own flake output — `binary-gnosis_vpn-x86_64-linux` ships root/worker/ctl only.
nix build -L --out-link "${GVPN_CLIENT_DIR}/result-system-tests" \
    "${GVPN_CLIENT_DIR}#binary-gnosis_vpn-system_tests"
test_binary="${GVPN_CLIENT_DIR}/result-system-tests/bin/gnosis_vpn-system_tests"

blokli_url=$(cat "${CONFIG_DIR}/blokli_url")

# Name the resolved target up front, so a failed run does not need this script to explain itself
echo "=== system test target ==="
echo "  blokli:      ${blokli_url}"
grep -o '^\[destinations\.[^]]*\]' "${CONFIG_DIR}/client.toml" | sed 's/^/  destination: /' || true
echo "  config:      ${CONFIG_DIR}/client.toml"
echo "  root:        ${root_binary}"
echo "  worker:      ${worker_binary}"
echo "  ctl:         ${ctl_binary}"
echo "  runner:      $(readlink -f "${test_binary}")"
echo "  worker user: $(id -un)"
echo "=========================="

# Refresh the sudo credential timestamp so the long run below doesn't hit a prompt later
sudo -v

stage_local_identity "$(blokli_network "${blokli_url}")" "${CONFIG_DIR}/extra_id.id" "${CONFIG_DIR}/extra_id.password"

# sudo's env_reset drops the environment, so every variable the spawned gnosis_vpn-root needs is
# restated here as an assignment on the command line.
sudo \
    CARGO_BIN_EXE_GNOSIS_VPN_ROOT="${root_binary}" \
    CARGO_BIN_EXE_GNOSIS_VPN_CTL="${ctl_binary}" \
    GNOSISVPN_CONFIG_PATH="${CONFIG_DIR}/client.toml" \
    GNOSISVPN_WORKER_BINARY="${worker_binary}" \
    SYSTEM_TEST_WORKER_USER="$(id -un)" \
    RUST_LOG="${SYSTEM_TEST_LOG_LEVEL}" \
    "${test_binary}" --blokliUrl "${blokli_url}" "$@"
