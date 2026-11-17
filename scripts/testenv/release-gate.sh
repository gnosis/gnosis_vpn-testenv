#!/usr/bin/env bash
# Release gate: every exit of GATE_NETWORK must connect and load the required sites (RELEASE_GATE.md).
#   release-gate.sh preflight         check every prerequisite; connects nothing
#   release-gate.sh run [e2e flags]   the gate; exits 0 only on PASS, flags go to e2e/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/common.sh"

: "${REPO_DIR:?}"
GATE_NETWORK="${GATE_NETWORK:-piz-palu-staging}"
NETWORK_DIR="${REPO_DIR}/configs/${GATE_NETWORK}"
GATE_CLIENT_BIN_DIR="${GATE_CLIENT_BIN_DIR:-${GVPN_CLIENT_DIR:-${REPO_DIR}/../gnosis_vpn-client}/target/release}"
PRODUCTS_CI_DIR="${PRODUCTS_CI_DIR:-${REPO_DIR}/../products-ci}"
IDENTITIES_YAML="${PRODUCTS_CI_DIR}/identities/${GATE_NETWORK}.yaml"
SECRETS_YAML="${PRODUCTS_CI_DIR}/identities/secrets.sops.yaml"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-${HOME}/.config/sops/age/keys.txt}"
export E2E_OUT_DIR="${GATE_OUT_DIR:-${REPO_DIR}/e2e/results/release-gate}"
# The packaged service runs with static routing (gnosis_vpn linux/resources/gnosisvpn.env)
export GNOSISVPN_FORCE_STATIC_ROUTING="${GNOSISVPN_FORCE_STATIC_ROUTING:-true}"

[ -f "${NETWORK_DIR}/network.env" ] ||
    die "Error: no ${NETWORK_DIR}/network.env; GATE_NETWORK names a configs/<network>/ dir"
# shellcheck source=/dev/null
source "${NETWORK_DIR}/network.env"
: "${GATE_BLOKLI_URL:?}" "${GATE_CHAIN_NETWORK:?}" "${GATE_SOPS_PASSWORD_PATH:?}"
GATE_CONFIG="${NETWORK_DIR}/config.toml"

identity_field() {
    NAME="${GVPN_IDENTITY}" yq ".clusterHoprd.identities[strenv(NAME)].$1" "${IDENTITIES_YAML}"
}

decrypt_password() {
    sops -d --extract "${GATE_SOPS_PASSWORD_PATH}" "${SECRETS_YAML}"
}

# The worker reads identity and password from the caller's home, keyed by Blokli's network name.
network_data_dir() {
    if [ "$(uname)" = "Darwin" ]; then
        echo "${HOME}/Library/Application Support/GnosisVPN/networks/${GATE_CHAIN_NETWORK}"
    else
        echo "${HOME}/.local/share/gnosisvpn/networks/${GATE_CHAIN_NETWORK}"
    fi
}

# config_path <key> <default> -> a top-level path key of the gate's client config, or the client's default
config_path() {
    local value
    value="$(sed -n "s/^$1 *= *\"\(.*\)\"/\1/p" "${GATE_CONFIG}")"
    echo "${value:-$2}"
}

preflight() {
    local problems=() bin cmd chain_network data_dir share geoip_db curvy_zk_dir
    [ -n "${GVPN_IDENTITY:-}" ] ||
        problems+=("GVPN_IDENTITY is not set: name the ${GATE_NETWORK} identity in ${IDENTITIES_YAML} the gate runs as")
    [ -n "${GATE_HOPRD_VERSION:-}" ] ||
        problems+=("GATE_HOPRD_VERSION is not set: the hoprd version under test, e.g. 5.0.3-pr.287")
    for bin in gnosis_vpn-root gnosis_vpn-worker gnosis_vpn-ctl; do
        [ -x "${GATE_CLIENT_BIN_DIR}/${bin}" ] ||
            problems+=("missing ${GATE_CLIENT_BIN_DIR}/${bin}: cargo build --release in gnosis_vpn-client, or set GATE_CLIENT_BIN_DIR")
    done
    for cmd in node npm obscura jq yq sops curl sudo; do
        command -v "${cmd}" >/dev/null 2>&1 || problems+=("missing ${cmd}: run inside nix develop")
    done

    if [ ! -f "${IDENTITIES_YAML}" ] || [ ! -f "${SECRETS_YAML}" ]; then
        problems+=("no products-ci checkout at ${PRODUCTS_CI_DIR} (clone it next to this repo, or set PRODUCTS_CI_DIR)")
    else
        if [ ! -f "${SOPS_AGE_KEY_FILE}" ]; then
            problems+=("no age key at ${SOPS_AGE_KEY_FILE}; set SOPS_AGE_KEY_FILE")
        elif ! decrypt_password >/dev/null 2>&1; then
            problems+=("sops cannot decrypt ${GATE_SOPS_PASSWORD_PATH} of ${SECRETS_YAML} with ${SOPS_AGE_KEY_FILE}: is your age key a recipient?")
        fi
        if [ -n "${GVPN_IDENTITY:-}" ] && [ "$(identity_field identityFile)" = "null" ]; then
            problems+=("GVPN_IDENTITY='${GVPN_IDENTITY}' is not in ${IDENTITIES_YAML}; known: $(yq '.clusterHoprd.identities | keys | join(" ")' "${IDENTITIES_YAML}")")
        fi
    fi

    if chain_network="$(blokli_network "${GATE_BLOKLI_URL}" 2>/dev/null)"; then
        [ "${chain_network}" = "${GATE_CHAIN_NETWORK}" ] ||
            problems+=("${GATE_BLOKLI_URL} reports chainInfo.network '${chain_network}', expected '${GATE_CHAIN_NETWORK}'")
    else
        problems+=("Blokli ${GATE_BLOKLI_URL} is unreachable or reports no chainInfo.network")
    fi

    # run.sh refuses to replace a different identity in your home: it may be your real one
    data_dir="$(network_data_dir)"
    if [ -f "${data_dir}/hopr.id" ] && [ -n "${GVPN_IDENTITY:-}" ] && [ -f "${IDENTITIES_YAML}" ] &&
        ! cmp -s <(identity_field identityFile | base64 -d) "${data_dir}/hopr.id"; then
        problems+=("${data_dir}/hopr.id holds another identity than ${GVPN_IDENTITY} (or one the client re-encrypted); move it away first")
    fi
    if [ -f "${data_dir}/hopr.pass" ] && [ -f "${SECRETS_YAML}" ] &&
        ! cmp -s <(printf %s "$(decrypt_password 2>/dev/null)") "${data_dir}/hopr.pass"; then
        problems+=("${data_dir}/hopr.pass holds another password than ${GATE_NETWORK}'s; move it away first")
    fi

    # Both have no default the client can do without, and only the installer puts them there.
    share=/usr/share/gnosisvpn
    [ "$(uname)" = "Darwin" ] && share=/usr/local/share/gnosisvpn
    geoip_db="$(config_path geoip_db "${share}/geoip.mmdb")"
    curvy_zk_dir="$(config_path curvy_zk_dir "${share}/curvy-zk")"
    [ -f "${geoip_db}" ] ||
        problems+=("no country database at ${geoip_db}: install the gnosisvpn package, or fetch https://download.gnosisvpn.io/geoip/latest.mmdb there")
    [ -d "${curvy_zk_dir}" ] ||
        problems+=("no Curvy proving files at ${curvy_zk_dir}: install the gnosisvpn package (or see the client's justfile system-tests recipe)")

    if pgrep -x gnosis_vpn-root >/dev/null 2>&1; then
        problems+=("a gnosis_vpn-root is already running (the installed service? sudo systemctl stop gnosisvpn)")
    fi

    if [ "${#problems[@]}" -gt 0 ]; then
        echo "release gate preflight FAILED (${GATE_NETWORK}):" >&2
        printf '  - %s\n' "${problems[@]}" >&2
        return 1
    fi
    sudo -n true 2>/dev/null || echo "note: sudo will ask for your password when the run starts"
    echo "release gate preflight ok: ${GATE_NETWORK}, identity ${GVPN_IDENTITY}, client ${GATE_CLIENT_BIN_DIR}, hoprd ${GATE_HOPRD_VERSION}"
}

# client_commit -> HEAD of the checkout holding the binaries, -dirty with local changes; empty outside a checkout
client_commit() {
    local commit
    commit="$(git -C "${GATE_CLIENT_BIN_DIR}" rev-parse HEAD 2>/dev/null)" || return 0
    [ -z "$(git -C "${GATE_CLIENT_BIN_DIR}" status --porcelain --untracked-files=no 2>/dev/null)" ] || commit="${commit}-dirty"
    echo "${commit}"
}

# The password must not outlive the run in your home; an identity that was there before stays.
cleanup() {
    rm -rf "${IDENTITY_DIR}"
    [ "${STAGED_PASS}" -eq 1 ] && rm -f "${DATA_DIR_IN_HOME}/hopr.pass"
    [ "${STAGED_ID}" -eq 1 ] && rm -f "${DATA_DIR_IN_HOME}/hopr.id"
    [ -e "${DATA_DIR_IN_HOME}/hopr.pass" ] && echo "note: ${DATA_DIR_IN_HOME}/hopr.pass predates the gate and was left in place"
    return 0
}

run_gate() {
    preflight

    local rc=0 run_dir verdict
    # globals: the EXIT trap runs after this function has returned
    DATA_DIR_IN_HOME="$(network_data_dir)"
    STAGED_ID=0
    STAGED_PASS=0
    [ -e "${DATA_DIR_IN_HOME}/hopr.id" ] || STAGED_ID=1
    [ -e "${DATA_DIR_IN_HOME}/hopr.pass" ] || STAGED_PASS=1

    IDENTITY_DIR="$(mktemp -d)"
    chmod 700 "${IDENTITY_DIR}"
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    identity_field identityFile | base64 -d >"${IDENTITY_DIR}/hopr.id"
    printf 'safe_address: "%s"\nmodule_address: "%s"\n' \
        "$(identity_field safeAddress)" "$(identity_field moduleAddress)" >"${IDENTITY_DIR}/hopr.safe"
    (
        umask 077
        decrypt_password >"${IDENTITY_DIR}/hopr.pass"
    )
    chmod 600 "${IDENTITY_DIR}"/hopr.*

    GATE_CLIENT_COMMIT="$(client_commit)"
    GATE_CLIENT_VERSION="$("${GATE_CLIENT_BIN_DIR}/gnosis_vpn-root" --version 2>/dev/null || true)"
    export GATE_NETWORK GVPN_IDENTITY GATE_HOPRD_VERSION GATE_CLIENT_COMMIT GATE_CLIENT_VERSION
    echo "== release gate on ${GATE_NETWORK}: client ${GATE_CLIENT_VERSION:-?} @ ${GATE_CLIENT_COMMIT:-?}, hoprd ${GATE_HOPRD_VERSION}"

    E2E_ROOT_BINARY="${GATE_CLIENT_BIN_DIR}/gnosis_vpn-root" \
        E2E_WORKER_BINARY="${GATE_CLIENT_BIN_DIR}/gnosis_vpn-worker" \
        GVPN_CTL="${GATE_CLIENT_BIN_DIR}/gnosis_vpn-ctl" \
        E2E_CONFIG="${GATE_CONFIG}" \
        E2E_IDENTITY_FILE="${IDENTITY_DIR}/hopr.id" \
        E2E_IDENTITY_PASS_FILE="${IDENTITY_DIR}/hopr.pass" \
        E2E_IDENTITY_SAFE_FILE="${IDENTITY_DIR}/hopr.safe" \
        E2E_BLOKLI_URL="${GATE_BLOKLI_URL}" \
        "${HERE}/e2e-on-network.sh" "$@" || rc=$?

    # run.sh names its run dir by start time; the identity dir was made just before it
    run_dir="$(find "${E2E_OUT_DIR}" -mindepth 1 -maxdepth 1 -type d -newer "${IDENTITY_DIR}" 2>/dev/null | sort | tail -1 || true)"
    verdict="$(jq -r '.verdict' "${run_dir:-/nonexistent}/verdict.json" 2>/dev/null || echo "none")"
    echo ""
    echo "== release gate ${GATE_NETWORK}: ${verdict} (e2e exit ${rc})"
    [ -n "${run_dir}" ] && echo "== report: ${run_dir}/report.md"
    [ "${verdict}" = "PASS" ]
}

case "${1:-}" in
preflight) preflight ;;
run)
    shift
    run_gate "$@"
    ;;
*) die "usage: release-gate.sh preflight | run [e2e/run.sh flags]" ;;
esac
