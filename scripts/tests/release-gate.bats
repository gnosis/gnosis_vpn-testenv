#!/usr/bin/env bats
# Offline tests for scripts/testenv/release-gate.sh: a throwaway repo, products-ci and client, with
# curl, sops and the e2e run faked. No network, no sudo, no VPN.

setup() {
    REPO_DIR="${BATS_TEST_TMPDIR}/repo"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    CLIENT_BIN="${BATS_TEST_TMPDIR}/client"
    export REPO_DIR HOME="${BATS_TEST_TMPDIR}/home"
    export GATE_NETWORK=test-net GVPN_IDENTITY=gate-1 GATE_HOPRD_VERSION=5.0.3-test
    export GATE_CLIENT_BIN_DIR="${CLIENT_BIN}" PRODUCTS_CI_DIR="${BATS_TEST_TMPDIR}/products-ci"
    export GATE_OUT_DIR="${BATS_TEST_TMPDIR}/results" SOPS_AGE_KEY_FILE="${BATS_TEST_TMPDIR}/age.txt"
    export FAKE_LOG="${BATS_TEST_TMPDIR}/e2e.log"
    DATA_DIR="${HOME}/.local/share/gnosisvpn/networks/test-net"
    mkdir -p "${REPO_DIR}/scripts/testenv" "${REPO_DIR}/configs/test-net" "${FAKE_BIN}" "${CLIENT_BIN}" \
        "${PRODUCTS_CI_DIR}/identities" "${HOME}" "${BATS_TEST_TMPDIR}/curvy-zk"
    cp "${BATS_TEST_DIRNAME}/../testenv/release-gate.sh" "${BATS_TEST_DIRNAME}/../testenv/common.sh" \
        "${REPO_DIR}/scripts/testenv/"
    touch "${SOPS_AGE_KEY_FILE}" "${BATS_TEST_TMPDIR}/geoip.mmdb" "${PRODUCTS_CI_DIR}/identities/secrets.sops.yaml"

    cat >"${REPO_DIR}/configs/test-net/network.env" <<'EOF'
GATE_BLOKLI_URL="http://blokli.invalid"
GATE_CHAIN_NETWORK="test-net"
GATE_SOPS_PASSWORD_PATH='["test"]["identityPassword"]'
EOF
    printf 'version = 7\ngeoip_db = "%s"\ncurvy_zk_dir = "%s"\n' \
        "${BATS_TEST_TMPDIR}/geoip.mmdb" "${BATS_TEST_TMPDIR}/curvy-zk" >"${REPO_DIR}/configs/test-net/config.toml"
    cat >"${PRODUCTS_CI_DIR}/identities/test-net.yaml" <<EOF
clusterHoprd:
  identities:
    gate-1:
      identityFile: "$(printf 'keystore-of-gate-1' | base64)"
      safeAddress: "0xSAFE"
      moduleAddress: "0xMODULE"
EOF

    fake "${FAKE_BIN}/curl" 'echo "{\"data\":{\"chainInfo\":{\"network\":\"${FAKE_CHAIN:-test-net}\"}}}"'
    fake "${FAKE_BIN}/sops" 'printf hunter2'
    fake "${FAKE_BIN}/pgrep" 'exit 1'
    for cmd in node npm obscura sudo; do fake "${FAKE_BIN}/${cmd}" 'exit 0'; done
    fake "${CLIENT_BIN}/gnosis_vpn-root" 'echo "gnosis_vpn-root 0.0.0"'
    fake "${CLIENT_BIN}/gnosis_vpn-worker" 'exit 0'
    fake "${CLIENT_BIN}/gnosis_vpn-ctl" 'exit 0'
    # Stands in for e2e/run.sh in spawn mode: stage the identity like it does, then leave a verdict.
    fake "${REPO_DIR}/scripts/testenv/e2e-on-network.sh" '
        { echo "argv: $*"; echo "pass-file: ${E2E_IDENTITY_PASS_FILE}"; echo "pass: $(cat "${E2E_IDENTITY_PASS_FILE}")"
          echo "safe: $(cat "${E2E_IDENTITY_SAFE_FILE}" | tr "\n" " ")"; } >"${FAKE_LOG}"
        dir="${HOME}/.local/share/gnosisvpn/networks/test-net"
        mkdir -p "${dir}"
        cp "${E2E_IDENTITY_FILE}" "${dir}/hopr.id"
        cp "${E2E_IDENTITY_PASS_FILE}" "${dir}/hopr.pass"
        mkdir -p "${E2E_OUT_DIR}/20261117T000000Z"
        echo "{\"verdict\":\"${FAKE_VERDICT:-PASS}\"}" >"${E2E_OUT_DIR}/20261117T000000Z/verdict.json"
        exit "${FAKE_RC:-0}"'
    export PATH="${FAKE_BIN}:${PATH}"
}

fake() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" >"$1"
    chmod +x "$1"
}

gate() { "${REPO_DIR}/scripts/testenv/release-gate.sh" "$@"; }

@test "preflight passes when everything is in place" {
    run gate preflight
    [ "$status" -eq 0 ]
    [[ "$output" == *"preflight ok: test-net, identity gate-1"* ]]
}

@test "preflight lists every problem at once" {
    rm "${CLIENT_BIN}/gnosis_vpn-worker"
    GVPN_IDENTITY="" GATE_HOPRD_VERSION="" run gate preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"GVPN_IDENTITY is not set"* ]]
    [[ "$output" == *"GATE_HOPRD_VERSION is not set"* ]]
    [[ "$output" == *"missing ${CLIENT_BIN}/gnosis_vpn-worker"* ]]
}

@test "preflight names the known identities when GVPN_IDENTITY is not one of them" {
    GVPN_IDENTITY=nobody run gate preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"GVPN_IDENTITY='nobody' is not in"*"known: gate-1"* ]]
}

@test "preflight fails when Blokli reports another network" {
    FAKE_CHAIN=jura-staging run gate preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"reports chainInfo.network 'jura-staging', expected 'test-net'"* ]]
}

@test "preflight fails when sops cannot decrypt" {
    fake "${FAKE_BIN}/sops" 'exit 1'
    run gate preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"sops cannot decrypt"* ]]
}

@test "preflight refuses another identity already in your home" {
    mkdir -p "${DATA_DIR}"
    echo "someone-elses-keystore" >"${DATA_DIR}/hopr.id"
    run gate preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"hopr.id holds another identity than gate-1"* ]]
}

@test "preflight fails on an unknown network" {
    GATE_NETWORK=nowhere run gate preflight
    [ "$status" -eq 1 ]
    [[ "$output" == *"configs/nowhere/network.env"* ]]
}

@test "a PASS run exits 0 and leaves neither the password nor the identity behind" {
    run gate run --quick
    [ "$status" -eq 0 ]
    [[ "$output" == *"release gate test-net: PASS"* ]]
    grep -qx 'argv: --quick' "${FAKE_LOG}"
    grep -qx 'pass: hunter2' "${FAKE_LOG}"
    grep -qx 'safe: safe_address: "0xSAFE" module_address: "0xMODULE" ' "${FAKE_LOG}"
    [ ! -e "${DATA_DIR}/hopr.pass" ]
    [ ! -e "${DATA_DIR}/hopr.id" ]
    [ ! -e "$(dirname "$(sed -n 's/^pass-file: //p' "${FAKE_LOG}")")" ]
    [[ "$output" != *hunter2* ]]
}

@test "a FAIL verdict fails the gate and still removes the password" {
    FAKE_VERDICT=FAIL FAKE_RC=1 run gate run
    [ "$status" -eq 1 ]
    [[ "$output" == *"release gate test-net: FAIL (e2e exit 1)"* ]]
    [ ! -e "${DATA_DIR}/hopr.pass" ]
}

@test "a run that produced no verdict fails the gate" {
    fake "${REPO_DIR}/scripts/testenv/e2e-on-network.sh" 'exit 2'
    run gate run
    [ "$status" -eq 1 ]
    [[ "$output" == *"release gate test-net: none (e2e exit 2)"* ]]
}

@test "a password that was in your home before the run is left in place" {
    mkdir -p "${DATA_DIR}"
    printf hunter2 >"${DATA_DIR}/hopr.pass"
    run gate run
    [ "$status" -eq 0 ]
    [ -e "${DATA_DIR}/hopr.pass" ]
    [[ "$output" == *"predates the gate and was left in place"* ]]
    [ ! -e "${DATA_DIR}/hopr.id" ]
}
